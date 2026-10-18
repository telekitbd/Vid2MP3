import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

class Log {
  static final List<String> lines = [];
  static File? _file;
  static final ValueNotifier<int> tick = ValueNotifier(0);

  static Future<void> init() async {
    try {
      final d = await getApplicationSupportDirectory();
      _file = File('${d.path}/app_log.txt');
      if (await _file!.exists()) {
        var t = await _file!.readAsString();
        if (t.length > 300000) {
          t = t.substring(t.length - 100000);
          await _file!.writeAsString(t);
        }
        lines.addAll(t.split('\n').where((e) => e.trim().isNotEmpty));
      }
    } catch (_) {}
    add('=== অ্যাপ চালু === Android: ${Platform.operatingSystemVersion}');
  }

  static void add(String m) {
    final t = DateTime.now().toString().substring(0, 19);
    final l = '[$t] $m';
    lines.add(l);
    if (lines.length > 3000) lines.removeRange(0, 800);
    try {
      _file?.writeAsStringSync('$l\n', mode: FileMode.append, flush: true);
    } catch (_) {}
    tick.value++;
  }

  static Future<void> clear() async {
    lines.clear();
    try {
      await _file?.writeAsString('');
    } catch (_) {}
    tick.value++;
  }

  static String text() => lines.join('\n');

  static String recent([int n = 400]) =>
      lines.skip(lines.length > n ? lines.length - n : 0).join('\n');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Log.init();
  FlutterError.onError = (d) {
    Log.add('FlutterError: ${d.exceptionAsString()}\n${d.stack}');
  };
  PlatformDispatcher.instance.onError = (e, st) {
    Log.add('PlatformError: $e\n$st');
    return true;
  };
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Vid2MP3',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: Colors.deepPurple, useMaterial3: true),
        home: const Home(),
      );
}

class Seg {
  final double start, end;
  final String text;
  Seg(this.start, this.end, this.text);
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  static const root = '/storage/emulated/0/AudioTool';

  int tab = 0;

  // প্রতিটা কাজের ফাইল আলাদা — একটা আরেকটার সাথে মিশবে না
  String? exVideo; // ট্যাব ১: এক্সট্রাক্টের ভিডিও
  String? aiVideo; // ট্যাব ২ক: AI ডাবের ভিডিও
  String? aiAudio; // ট্যাব ২খ: AI ডাবের অডিও
  String? rpVideo; // ট্যাব ৩: রিপ্লেসের ভিডিও
  String? rpAudio; // ট্যাব ৩: রিপ্লেসের নতুন অডিও

  String lang = 'bn';
  final keyCtrl = TextEditingController();
  bool keyVisible = false;
  String savedKey = '';
  String keyMsg = '';

  // Gemini (ছেলে/মেয়ে সনাক্ত)
  final gKeyCtrl = TextEditingController();
  bool gKeyVisible = false;
  String savedGKey = '';
  String gKeyMsg = '';
  bool useGender = true;
  double bgVol = 0; // 0 = ব্যাকগ্রাউন্ড সাউন্ড বন্ধ

  bool busy = false;
  String busyName = '';
  String label = '';
  double progress = 0;
  bool fallbackUsed = false;
  bool storageOk = false;

  final Map<String, String> results = {};
  final Map<String, String> status = {};

  @override
  void initState() {
    super.initState();
    _readKey().then((k) {
      if (!mounted) return;
      setState(() {
        keyCtrl.text = k;
        savedKey = k;
        keyMsg = k.isEmpty ? '' : '✅ সেভ করা key আছে';
      });
    });
    _readKey('gemini_key.txt').then((k) {
      if (!mounted) return;
      setState(() {
        gKeyCtrl.text = k;
        savedGKey = k;
        gKeyMsg = k.isEmpty ? '' : '✅ সেভ করা Gemini key আছে';
      });
    });
  }

  Future<void> _saveGKey() async {
    final k = gKeyCtrl.text.trim();
    if (k.isEmpty) return _toast('আগে Gemini key লিখুন');
    await _writeKey(k, 'gemini_key.txt');
    setState(() {
      savedGKey = k;
      gKeyMsg = '✅ সেভ হয়েছে, চেক করা হচ্ছে...';
    });
    try {
      final r = await http.get(
          Uri.parse('https://generativelanguage.googleapis.com/v1beta/models'),
          headers: {'x-goog-api-key': k});
      if (!mounted) return;
      setState(() => gKeyMsg = r.statusCode == 200
          ? '✅ Gemini key সেভ হয়েছে ও ঠিক আছে'
          : (r.statusCode == 400 || r.statusCode == 403)
              ? '⚠️ সেভ হয়েছে, কিন্তু key ভুল মনে হচ্ছে'
              : '✅ সেভ হয়েছে (চেক করা যায়নি: ${r.statusCode})');
    } catch (_) {
      if (!mounted) return;
      setState(() => gKeyMsg = '✅ সেভ হয়েছে (ইন্টারনেট নেই, চেক হয়নি)');
    }
  }

  Future<void> _deleteGKey() async {
    await _removeKeyFile('gemini_key.txt');
    setState(() {
      gKeyCtrl.clear();
      savedGKey = '';
      gKeyMsg = '🗑️ Gemini key মুছে ফেলা হয়েছে';
    });
  }

  Future<void> _saveKey() async {
    final k = keyCtrl.text.trim();
    if (k.isEmpty) return _toast('আগে key লিখুন');
    await _writeKey(k);
    setState(() {
      savedKey = k;
      keyMsg = '✅ সেভ হয়েছে, চেক করা হচ্ছে...';
    });
    try {
      final r = await http.get(
          Uri.parse('https://api.groq.com/openai/v1/models'),
          headers: {'Authorization': 'Bearer $k'});
      if (!mounted) return;
      setState(() => keyMsg = r.statusCode == 200
          ? '✅ Key সেভ হয়েছে ও ঠিক আছে'
          : r.statusCode == 401
              ? '⚠️ সেভ হয়েছে, কিন্তু key ভুল মনে হচ্ছে'
              : '✅ সেভ হয়েছে (চেক করা যায়নি: ${r.statusCode})');
    } catch (_) {
      if (!mounted) return;
      setState(() => keyMsg = '✅ সেভ হয়েছে (ইন্টারনেট নেই, চেক হয়নি)');
    }
  }

  Future<void> _deleteKey() async {
    await _removeKeyFile();
    setState(() {
      keyCtrl.clear();
      savedKey = '';
      keyMsg = '🗑️ Key মুছে ফেলা হয়েছে';
    });
  }

  // ---------- API key ফাইলে সেভ (shared_preferences ছাড়া) ----------
  Future<File> _keyFile([String n = 'groq_key.txt']) async =>
      File('${(await getApplicationSupportDirectory()).path}/$n');

  Future<String> _readKey([String n = 'groq_key.txt']) async {
    try {
      final f = await _keyFile(n);
      return await f.exists() ? (await f.readAsString()).trim() : '';
    } catch (e) {
      Log.add('key পড়া যায়নি: $e');
      return '';
    }
  }

  Future<void> _writeKey(String k, [String n = 'groq_key.txt']) async {
    try {
      await (await _keyFile(n)).writeAsString(k);
    } catch (e) {
      Log.add('key সেভ হয়নি: $e');
    }
  }

  Future<void> _removeKeyFile([String n = 'groq_key.txt']) async {
    try {
      final f = await _keyFile(n);
      if (await f.exists()) await f.delete();
    } catch (e) {
      Log.add('key মোছা যায়নি: $e');
    }
  }

  void _openLogs() => Navigator.push(
      context, MaterialPageRoute(builder: (_) => const LogPage()));

  String _tail(String s, int n) =>
      s.length <= n ? s : '…${s.substring(s.length - n)}';

  // ---------- ছোট হেল্পার ----------
  void _toast(String m) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  void _step(String l, [double? p]) {
    if (l != label) Log.add(l);
    if (!mounted) return;
    setState(() {
      label = l;
      if (p != null) progress = p.clamp(0.0, 1.0);
    });
  }

  String _fileName(String? p) => p == null ? 'বাছাই করা হয়নি' : p.split('/').last;

  String _base(String p) {
    var n = p.split('/').last;
    final i = n.lastIndexOf('.');
    if (i > 0) n = n.substring(0, i);
    n = n.replaceAll(RegExp(r'[^A-Za-z0-9_\-\u0980-\u09FF]'), '_');
    return n.length > 40 ? n.substring(0, 40) : n;
  }

  String _ts() {
    final d = DateTime.now();
    String t(int x) => x.toString().padLeft(2, '0');
    return '${d.year}${t(d.month)}${t(d.day)}_${t(d.hour)}${t(d.minute)}${t(d.second)}';
  }

  Future<String?> _pick(FileType type) async {
    final r = await FilePicker.platform.pickFiles(type: type);
    return r?.files.single.path;
  }

  // ---------- স্টোরেজ ----------
  Future<void> _ensureStorage() async {
    if (!Platform.isAndroid) return;
    var ok = await Permission.manageExternalStorage.isGranted;
    if (!ok) ok = (await Permission.manageExternalStorage.request()).isGranted;
    if (!ok) ok = (await Permission.storage.request()).isGranted;
    storageOk = ok;
    Log.add('স্টোরেজ পারমিশন: ${ok ? "পেয়েছে" : "পায়নি"}');
  }

  Future<String> _save(String tmp, String sub, String base, String ext) async {
    Directory dir;
    if (storageOk) {
      dir = Directory('$root/$sub');
      try {
        await dir.create(recursive: true);
      } catch (_) {
        storageOk = false;
      }
    }
    if (!storageOk) {
      fallbackUsed = true;
      final b = (await getExternalStorageDirectory()) ??
          await getApplicationDocumentsDirectory();
      dir = Directory('${b.path}/$sub');
      await dir.create(recursive: true);
    } else {
      dir = Directory('$root/$sub');
    }
    final dest = '${dir.path}/${base}_${_ts()}.$ext';
    await File(tmp).copy(dest);
    try {
      await File(tmp).delete();
    } catch (_) {}
    return dest;
  }

  Future<String> _tmp(String ext) async {
    final d = await getTemporaryDirectory();
    return '${d.path}/t_${DateTime.now().microsecondsSinceEpoch}.$ext';
  }

  // ---------- ffmpeg ----------
  Future<bool> _ff(List<String> args,
      {double? total, double from = 0, double to = 1}) async {
    Log.add('ffmpeg: ${_tail(args.join(" "), 400)}');
    final c = Completer<bool>();
    await FFmpegKit.executeWithArgumentsAsync(args, (s) async {
      final rc = await s.getReturnCode();
      final ok = ReturnCode.isSuccess(rc);
      if (!ok) {
        final out = await s.getAllLogsAsString() ?? '';
        Log.add('ffmpeg ব্যর্থ (code ${rc?.getValue()}):\n${_tail(out, 2500)}');
      }
      c.complete(ok);
    }, null, total == null
        ? null
        : (stat) {
            final num t = stat.getTime();
            if (t > 0 && total > 0) {
              final f = ((t / 1000) / total).clamp(0.0, 1.0);
              _step(label, from + (to - from) * f);
            }
          });
    return c.future;
  }

  Future<double> _dur(String p) async {
    final s = await FFmpegKit.executeWithArguments(['-i', p]);
    final log = await s.getAllLogsAsString() ?? '';
    final m = RegExp(r'Duration: (\d+):(\d+):(\d+\.?\d*)').firstMatch(log);
    if (m == null) return 0;
    return int.parse(m[1]!) * 3600 +
        int.parse(m[2]!) * 60 +
        double.parse(m[3]!);
  }

  // ---------- কাজ চালানোর কমন সিস্টেম ----------
  Future<void> _start(String k, String name, Future<String> Function() job) async {
    if (busy) {
      _toast('⏳ "$busyName" এখনো চলছে। শেষ না হওয়া পর্যন্ত অপেক্ষা করুন।');
      return;
    }
    Log.add('▶ "$name" শুরু');
    setState(() {
      busy = true;
      busyName = name;
      label = 'শুরু হচ্ছে...';
      progress = 0;
      fallbackUsed = false;
      results.remove(k);
      status[k] = '⏳ কাজ চলছে...';
    });
    try {
      final p = await job();
      Log.add('✅ "$name" সম্পন্ন → $p');
      setState(() {
        results[k] = p;
        progress = 1;
        status[k] = '✅ সম্পন্ন!'
            '${fallbackUsed ? "\n(স্টোরেজ পারমিশন না দেওয়ায় অ্যাপের নিজস্ব ফোল্ডারে সেভ হয়েছে)" : ""}';
      });
      _toast('✅ $name শেষ হয়েছে');
    } catch (e, st) {
      Log.add('❌ "$name" ব্যর্থ: $e\n$st');
      final m = e.toString();
      setState(() => status[k] =
          '❌ ব্যর্থ: ${m.length > 160 ? "${m.substring(0, 160)}…" : m}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  // ---------- কাজ ১: অডিও এক্সট্রাক্ট ----------
  Future<String> _jobExtract(String video) async {
    _step('পারমিশন চেক...', 0.01);
    await _ensureStorage();
    _step('MP3 বের হচ্ছে...', 0.03);
    final total = await _dur(video);
    final tmp = await _tmp('mp3');
    final ok = await _ff(
        ['-y', '-i', video, '-vn', '-c:a', 'libmp3lame', '-b:a', '192k', tmp],
        total: total, from: 0.03, to: 0.97);
    if (!ok) throw 'এক্সট্রাক্ট হয়নি (ভিডিওতে অডিও আছে?)';
    _step('ফাইল সেভ হচ্ছে...', 0.98);
    return _save(tmp, 'Extracted_Audio', _base(video), 'mp3');
  }

  // ---------- কাজ ২: অডিও রিপ্লেস ----------
  Future<String> _jobReplace(String video, String audio) async {
    _step('পারমিশন চেক...', 0.01);
    await _ensureStorage();
    _step('ভিডিওতে নতুন অডিও বসছে...', 0.03);
    final total = await _dur(video);
    final tmp = await _tmp('mp4');
    final ok = await _ff([
      '-y', '-i', video, '-i', audio,
      '-map', '0:v:0', '-map', '1:a:0',
      '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k', '-shortest', tmp
    ], total: total, from: 0.03, to: 0.97);
    if (!ok) throw 'অডিও রিপ্লেস হয়নি';
    _step('ফাইল সেভ হচ্ছে...', 0.98);
    return _save(tmp, 'Replaced_Video', _base(video), 'mp4');
  }

  // ---------- কাজ ৩: AI ডাব ----------
  Future<List<Seg>> _transcribe(String audio, String key) async {
    final req = http.MultipartRequest(
        'POST', Uri.parse('https://api.groq.com/openai/v1/audio/transcriptions'));
    req.headers['Authorization'] = 'Bearer $key';
    req.fields['model'] = 'whisper-large-v3';
    req.fields['response_format'] = 'verbose_json';
    req.files.add(await http.MultipartFile.fromPath('file', audio));
    final res = await http.Response.fromStream(await req.send());
    if (res.statusCode != 200) {
      Log.add('Groq ${res.statusCode}: ${_tail(utf8.decode(res.bodyBytes), 400)}');
      throw 'Groq error ${res.statusCode} (key ঠিক আছে?)';
    }
    final j = jsonDecode(utf8.decode(res.bodyBytes));
    final list = (j['segments'] as List?) ?? [];
    return list
        .map((e) => Seg((e['start'] as num).toDouble(),
            (e['end'] as num).toDouble(), (e['text'] as String).trim()))
        .where((s) => s.text.isNotEmpty)
        .toList();
  }

  Future<T> _retry<T>(Future<T> Function() f, {int n = 4}) async {
    for (var i = 1;; i++) {
      try {
        return await f();
      } catch (e) {
        if (i >= n) rethrow;
        Log.add('নেটওয়ার্ক সমস্যা, আবার চেষ্টা ($i/${n - 1}): '
            '${_tail(e.toString(), 120)}');
        await Future.delayed(Duration(seconds: 2 * i));
      }
    }
  }

  Future<String> _translate(String t, String tl) async {
    final uri = Uri.https('translate.googleapis.com', '/translate_a/single',
        {'client': 'gtx', 'sl': 'auto', 'tl': tl, 'dt': 't', 'q': t});
    final res = await http.get(uri);
    if (res.statusCode != 200) throw 'Translate error ${res.statusCode}';
    final j = jsonDecode(utf8.decode(res.bodyBytes));
    return (j[0] as List).map((e) => (e[0] ?? '') as String).join();
  }

  List<String> _chunks(String t, [int max = 180]) {
    final out = <String>[];
    var cur = '';
    for (final w in t.split(' ')) {
      if ((cur + ' ' + w).length > max && cur.isNotEmpty) {
        out.add(cur);
        cur = w;
      } else {
        cur = cur.isEmpty ? w : '$cur $w';
      }
    }
    if (cur.isNotEmpty) out.add(cur);
    return out;
  }

  Future<void> _tts(String text, String tl, String path) async {
    final sink = File(path).openWrite();
    for (final c in _chunks(text)) {
      final uri = Uri.https('translate.google.com', '/translate_tts', {
        'ie': 'UTF-8', 'client': 'tw-ob', 'tl': tl, 'q': c,
      });
      final res = await http.get(uri, headers: {'User-Agent': 'Mozilla/5.0'});
      if (res.statusCode != 200) {
        await sink.close();
        throw 'TTS error ${res.statusCode}';
      }
      sink.add(res.bodyBytes);
    }
    await sink.close();
  }

  // ---------- Gemini: কে ছেলে, কে মেয়ে ----------
  Future<void> _identify(String src, List<Seg> segs, String gKey,
      List<String> out, int id, String dir) async {
    final small = '$dir/gem_$id.mp3';
    if (!await _ff(['-y', '-i', src, '-vn', '-ac', '1', '-ar', '16000',
      '-c:a', 'libmp3lame', '-b:a', '24k', small])) {
      throw 'Gemini-র জন্য অডিও বানানো যায়নি';
    }
    final bytes = await File(small).readAsBytes();
    try {
      await File(small).delete();
    } catch (_) {}
    if (bytes.length > 14 * 1024 * 1024) {
      throw 'অডিও অনেক লম্বা (Gemini-তে সরাসরি পাঠানো যায় না)';
    }
    final list = StringBuffer();
    for (var i = 0; i < segs.length; i++) {
      final s = segs[i];
      final t = String.fromCharCodes(s.text.runes.take(50));
      list.writeln(
          '$i | ${s.start.toStringAsFixed(1)}-${s.end.toStringAsFixed(1)} | $t');
    }
    final prompt =
        'Below is a list of speech segments from the attached audio, as '
        '"id | start-end seconds | text". For EVERY id, listen to that time '
        'range and decide whether the speaker is male or female, and give a '
        'consistent speaker number (the same person always gets the same '
        'number, starting from 1). Return a JSON array with one object per '
        'id, in order.\n\n$list';
    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {'inline_data': {'mime_type': 'audio/mp3', 'data': base64Encode(bytes)}},
            {'text': prompt},
          ]
        }
      ],
      'generationConfig': {
        'temperature': 0,
        'responseMimeType': 'application/json',
        'responseSchema': {
          'type': 'ARRAY',
          'items': {
            'type': 'OBJECT',
            'properties': {
              'id': {'type': 'INTEGER'},
              'gender': {
                'type': 'STRING',
                'enum': ['male', 'female']
              },
              'speaker': {'type': 'INTEGER'},
            },
            'required': ['id', 'gender', 'speaker'],
          },
        },
      },
    });

    const models = [
      'gemini-3.8-flash',
      'gemini-3.5-flash-lite',
      'gemini-3.5-flash',
      'gemini-3.1-flash-lite',
    ];
    String lastErr = 'unknown';
    for (final m in models) {
      Log.add('Gemini মডেল: $m');
      http.Response? resp;
      for (var attempt = 1; attempt <= 3 && resp == null; attempt++) {
        try {
          resp = await http
              .post(
                  Uri.parse(
                      'https://generativelanguage.googleapis.com/v1beta/models/$m:generateContent'),
                  headers: {
                    'Content-Type': 'application/json',
                    'x-goog-api-key': gKey,
                  },
                  body: body)
              .timeout(const Duration(minutes: 5));
        } catch (e) {
          lastErr = '$m: $e';
          Log.add('Gemini অনুরোধ ব্যর্থ (চেষ্টা $attempt/3): $e');
          if (attempt < 3) await Future.delayed(Duration(seconds: 3 * attempt));
        }
      }
      if (resp == null) continue;
      final res = resp;
      if (res.statusCode != 200) {
        lastErr = '$m: HTTP ${res.statusCode}';
        Log.add('Gemini ${res.statusCode}: ${_tail(utf8.decode(res.bodyBytes), 400)}');
        if (res.statusCode == 400 ||
            res.statusCode == 401 ||
            res.statusCode == 403) {
          throw 'Gemini key ঠিক নেই? ($lastErr)';
        }
        continue;
      }
      try {
        final j = jsonDecode(utf8.decode(res.bodyBytes));
        final parts = j['candidates'][0]['content']['parts'] as List;
        var txt = parts.map((e) => (e['text'] ?? '') as String).join();
        txt = txt.replaceAll(RegExp(r'```json|```'), '').trim();
        final arr = jsonDecode(txt) as List;
        var male = 0, female = 0;
        final speakers = <int>{};
        for (final e in arr) {
          final i = (e['id'] as num).toInt();
          if (i < 0 || i >= out.length) continue;
          final g = (e['gender'] as String).toLowerCase();
          out[i] = g.startsWith('m') ? 'male' : 'female';
          final sp = e['speaker'];
          if (sp is num) speakers.add(sp.toInt());
        }
        for (final g in out) {
          g == 'male' ? male++ : female++;
        }
        Log.add('Gemini সনাক্ত: ছেলে $male, মেয়ে $female, '
            'আলাদা বক্তা ${speakers.length}');
        return;
      } catch (e) {
        lastErr = '$m: উত্তর পড়া যায়নি ($e)';
        Log.add(lastErr);
      }
    }
    throw lastErr;
  }

  // ছেলের ভয়েস: পিচ কমানো (গতি একই রেখে)
  Future<String> _maleVoice(String f) async {
    final o = f.replaceFirst(RegExp(r'\.mp3$'), '_m.mp3');
    final ok = await _ff([
      '-y', '-i', f, '-af',
      'aresample=24000,asetrate=19680,aresample=24000,atempo=1.2195',
      '-c:a', 'libmp3lame', '-b:a', '64k', o
    ]);
    if (!ok) return f;
    try {
      await File(f).delete();
    } catch (_) {}
    return o;
  }

  Future<String> _jobAi(String src, bool audioOnly) async {
    final key = keyCtrl.text.trim();
    if (key.isEmpty) throw 'আগে Groq API key দিন (ফ্রি)';
    await _writeKey(key);
    final gKey = gKeyCtrl.text.trim();
    final detect = useGender && gKey.isNotEmpty;
    if (gKey.isNotEmpty) await _writeKey(gKey, 'gemini_key.txt');
    if (useGender && gKey.isEmpty) {
      Log.add('Gemini key নেই — সবাই একই ভয়েসে ডাব হবে');
    }

    _step('পারমিশন চেক...', 0.01);
    await _ensureStorage();

    final id = DateTime.now().millisecondsSinceEpoch;
    final tmpDir = await getTemporaryDirectory();
    final total = await _dur(src);

    _step('১/৫ অডিও বের হচ্ছে...', 0.03);
    final mp3 = '${tmpDir.path}/src_$id.mp3';
    if (!await _ff(['-y', '-i', src, '-vn', '-ac', '1', '-ar', '16000',
      '-c:a', 'libmp3lame', '-b:a', '48k', mp3])) {
      throw 'অডিও এক্সট্রাক্ট হয়নি';
    }

    _step('২/৫ কথা শুনে টেক্সট করা হচ্ছে (একটু সময় লাগবে)...', 0.08);
    final segs = await _retry(() => _transcribe(mp3, key), n: 3);
    if (segs.isEmpty) throw 'কোনো কথা পাওয়া যায়নি';

    // ছেলে/মেয়ে — ব্যর্থ হলে সবাই 'female' (আগের মতো একই ভয়েস)
    final genders = List<String>.filled(segs.length, 'female');
    if (detect) {
      _step('৩/৫ ছেলে-মেয়ে চেনা হচ্ছে (Gemini)...', 0.18);
      try {
        await _identify(src, segs, gKey, genders, id, tmpDir.path);
      } catch (e) {
        Log.add('⚠️ Gemini সনাক্ত ব্যর্থ, সবাই একই ভয়েসে ডাব হবে: $e');
        for (var i = 0; i < genders.length; i++) {
          genders[i] = 'female';
        }
      }
    }

    final files = <String>[];
    final used = <Seg>[];
    for (var i = 0; i < segs.length; i++) {
      _step('৪/৫ অনুবাদ ও ভয়েস তৈরি ${i + 1}/${segs.length}',
          0.25 + 0.60 * (i / segs.length));
      final tr = await _retry(() => _translate(segs[i].text, lang));
      if (tr.trim().isEmpty) continue;
      var f = '${tmpDir.path}/seg_${id}_$i.mp3';
      await _retry(() => _tts(tr, lang, f));
      if (genders[i] == 'male') f = await _maleVoice(f);
      files.add(f);
      used.add(segs[i]);
    }
    if (files.isEmpty) throw 'ভয়েস তৈরি হয়নি';

    _step('৫/৫ ফাইনাল ফাইল তৈরি হচ্ছে...', 0.86);
    final fc = StringBuffer();
    final labels = StringBuffer();
    for (var i = 0; i < files.length; i++) {
      final s = used[i];
      final nextStart = i + 1 < used.length ? used[i + 1].start : s.end + 1.0;
      final slot = (nextStart - s.start).clamp(0.5, 1000.0);
      final d = await _dur(files[i]);
      var tempo = d > slot ? d / slot : 1.0;
      if (tempo > 1.8) tempo = 1.8;
      final ms = (s.start * 1000).round();
      final t = tempo > 1.01 ? 'atempo=${tempo.toStringAsFixed(3)},' : '';
      // ইনপুট ০ = আসল ফাইল (ব্যাকগ্রাউন্ডের জন্য), ভয়েস ফাইল ১ থেকে
      fc.write('[${i + 1}:a]${t}adelay=$ms|$ms[a$i];');
      labels.write('[a$i]');
    }
    final hasBg = bgVol > 0;
    if (hasBg) {
      fc.write('[0:a]volume=${bgVol.toStringAsFixed(2)}[bg];');
      labels.write('[bg]');
    }
    final n = files.length + (hasBg ? 1 : 0);
    fc.write('${labels}amix=inputs=$n:duration=longest:normalize=0[out]');

    final tmp = await _tmp(audioOnly ? 'mp3' : 'mp4');
    final List<String> args = ['-y', '-i', src];
    for (final f in files) {
      args.addAll(['-i', f]);
    }
    if (audioOnly) {
      args.addAll(['-filter_complex', fc.toString(), '-map', '[out]',
        '-c:a', 'libmp3lame', '-b:a', '192k', tmp]);
    } else {
      args.addAll(['-filter_complex', fc.toString(), '-map', '0:v:0',
        '-map', '[out]', '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k', tmp]);
    }
    if (!await _ff(args, total: total, from: 0.86, to: 0.97)) {
      throw 'ফাইনাল ফাইল তৈরি হয়নি';
    }

    for (final f in files) {
      try {
        await File(f).delete();
      } catch (_) {}
    }
    try {
      await File(mp3).delete();
    } catch (_) {}

    _step('ফাইল সেভ হচ্ছে...', 0.98);
    return audioOnly
        ? _save(tmp, 'AI_Dubbed_Audio', _base(src), 'mp3')
        : _save(tmp, 'AI_Dubbed_Video', _base(src), 'mp4');
  }

  // ---------- UI কম্পোনেন্ট ----------
  Widget _title(String t, String sub) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(sub, style: TextStyle(color: Colors.grey.shade700)),
        ]),
      );

  Widget _fileTile(String title, IconData icon, String? path, VoidCallback onPick) {
    return Card(
      child: ListTile(
        leading: Icon(icon, color: path == null ? null : Colors.green),
        title: Text(title),
        subtitle: Text(_fileName(path), maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: FilledButton.tonal(
            onPressed: busy ? () => _toast('⏳ কাজ চলছে, একটু অপেক্ষা করুন') : onPick,
            child: Text(path == null ? 'Select' : 'Change')),
      ),
    );
  }

  Widget _action(String text, IconData icon, VoidCallback onTap) => FilledButton.icon(
        onPressed: onTap,
        icon: Icon(icon),
        label: Text(text),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      );

  Widget _result(String k) {
    final st = status[k];
    if (st == null) return const SizedBox();
    final p = results[k];
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(st, style: const TextStyle(fontWeight: FontWeight.w600)),
          if (st.startsWith('❌')) ...[
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: _openLogs,
              icon: const Icon(Icons.bug_report),
              label: const Text('📋 লগ দেখুন'),
            ),
          ],
          if (p != null) ...[
            const SizedBox(height: 6),
            const Text('সেভ হয়েছে:', style: TextStyle(fontSize: 12)),
            SelectableText(p, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: () => Share.shareXFiles([XFile(p)]),
              icon: const Icon(Icons.share),
              label: const Text('Share'),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _progressCard() {
    final pct = (progress * 100).round();
    return Material(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text('⏳ $busyName চলছে',
                    style: const TextStyle(fontWeight: FontWeight.bold))),
            Text('$pct%', style: const TextStyle(fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: progress <= 0 ? null : progress),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(fontSize: 12)),
        ]),
      ),
    );
  }

  // ---------- ট্যাব ১: এক্সট্রাক্ট ----------
  Widget _tabExtract() => ListView(padding: const EdgeInsets.all(16), children: [
        _title('🎵 ভিডিও থেকে অডিও বের করুন',
            'ভিডিও দিন → MP3 অডিও ফাইল পাবেন।'),
        _fileTile('ধাপ ১: ভিডিও সিলেক্ট', Icons.movie, exVideo, () async {
          final p = await _pick(FileType.video);
          if (p != null) setState(() => exVideo = p);
        }),
        const SizedBox(height: 8),
        _action('ধাপ ২: MP3 এক্সট্রাক্ট করুন', Icons.audiotrack, () {
          if (exVideo == null) return _toast('আগে ভিডিও সিলেক্ট করুন');
          _start('ex', 'অডিও এক্সট্রাক্ট', () => _jobExtract(exVideo!));
        }),
        const SizedBox(height: 12),
        _result('ex'),
        const Text('📁 সেভ হবে: Internal storage / AudioTool / Extracted_Audio',
            style: TextStyle(fontSize: 12)),
      ]);

  // ---------- ট্যাব ২: AI ডাব ----------
  Widget _tabAi() => ListView(padding: const EdgeInsets.all(16), children: [
        _title('🤖 AI অটো ডাব (বাংলা / হিন্দি)',
            'যেকোনো ভাষার কথা নিজে থেকে বাংলা বা হিন্দিতে ডাব হবে। Gemini key দিলে ছেলে-মেয়ে আলাদা ভয়েস পাবেন।'),
        TextField(
          controller: keyCtrl,
          obscureText: !keyVisible,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: 'Groq API Key (ফ্রি)',
            helperText: 'console.groq.com/keys থেকে ফ্রিতে নিন',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: Icon(keyVisible ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => keyVisible = !keyVisible),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: keyCtrl.text.trim().isEmpty ||
                      keyCtrl.text.trim() == savedKey
                  ? null
                  : _saveKey,
              icon: const Icon(Icons.save),
              label: const Text('Key সেভ করুন'),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: savedKey.isEmpty ? null : _deleteKey,
            icon: const Icon(Icons.delete_outline),
            label: const Text('মুছুন'),
          ),
        ]),
        if (keyMsg.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(keyMsg, style: const TextStyle(fontSize: 12)),
          ),
        const SizedBox(height: 14),
        TextField(
          controller: gKeyCtrl,
          obscureText: !gKeyVisible,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: 'Gemini API Key (ফ্রি) — ছেলে/মেয়ে চেনার জন্য',
            helperText: 'aistudio.google.com/apikey থেকে ফ্রিতে নিন',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: Icon(gKeyVisible ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => gKeyVisible = !gKeyVisible),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: gKeyCtrl.text.trim().isEmpty ||
                      gKeyCtrl.text.trim() == savedGKey
                  ? null
                  : _saveGKey,
              icon: const Icon(Icons.save),
              label: const Text('Gemini key সেভ'),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: savedGKey.isEmpty ? null : _deleteGKey,
            icon: const Icon(Icons.delete_outline),
            label: const Text('মুছুন'),
          ),
        ]),
        if (gKeyMsg.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(gKeyMsg, style: const TextStyle(fontSize: 12)),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('ছেলে-মেয়ে আলাদা ভয়েস (অটো সনাক্ত)'),
          subtitle: const Text(
              'বন্ধ থাকলে বা Gemini key না থাকলে সবাই একই ভয়েসে ডাব হবে। '
              'ছেলের ভয়েস = পিচ কমানো ভয়েস।'),
          value: useGender,
          onChanged: (v) => setState(() => useGender = v),
        ),
        Text(
            'ব্যাকগ্রাউন্ড সাউন্ড (আসল অডিও নিচে রাখা): '
            '${bgVol <= 0 ? "বন্ধ" : "${(bgVol * 100).round()}%"}',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        Slider(
          value: bgVol,
          min: 0,
          max: 0.4,
          divisions: 8,
          label: bgVol <= 0 ? 'বন্ধ' : '${(bgVol * 100).round()}%',
          onChanged: (v) => setState(() => bgVol = v),
        ),
        const Text(
            'মিউজিক/সাউন্ড ইফেক্ট আলাদা করা যায় না — তাই আসল অডিও হালকা ভলিউমে থাকবে, '
            'আসল কথাও আবছা শোনা যাবে।',
            style: TextStyle(fontSize: 12)),
        const SizedBox(height: 10),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'bn', label: Text('বাংলা')),
            ButtonSegment(value: 'hi', label: Text('हिन्दी')),
          ],
          selected: {lang},
          onSelectionChanged: (s) => setState(() => lang = s.first),
        ),
        const Divider(height: 32),
        const Text('ক) ভিডিও → ডাব করা ভিডিও',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 8),
        _fileTile('ভিডিও সিলেক্ট', Icons.movie, aiVideo, () async {
          final p = await _pick(FileType.video);
          if (p != null) setState(() => aiVideo = p);
        }),
        const SizedBox(height: 8),
        _action('ভিডিও AI ডাব করুন', Icons.auto_awesome, () {
          if (aiVideo == null) return _toast('আগে ভিডিও সিলেক্ট করুন');
          _start('aiV', 'AI ভিডিও ডাব', () => _jobAi(aiVideo!, false));
        }),
        _result('aiV'),
        const Text('📁 AudioTool / AI_Dubbed_Video',
            style: TextStyle(fontSize: 12)),
        const Divider(height: 32),
        const Text('খ) অডিও → ডাব করা MP3',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 8),
        _fileTile('অডিও সিলেক্ট', Icons.audio_file, aiAudio, () async {
          final p = await _pick(FileType.audio);
          if (p != null) setState(() => aiAudio = p);
        }),
        const SizedBox(height: 8),
        _action('অডিও AI ডাব করুন (MP3)', Icons.auto_awesome, () {
          if (aiAudio == null) return _toast('আগে অডিও সিলেক্ট করুন');
          _start('aiA', 'AI অডিও ডাব', () => _jobAi(aiAudio!, true));
        }),
        _result('aiA'),
        const Text('📁 AudioTool / AI_Dubbed_Audio',
            style: TextStyle(fontSize: 12)),
      ]);

  // ---------- ট্যাব ৩: রিপ্লেস ----------
  Widget _tabReplace() => ListView(padding: const EdgeInsets.all(16), children: [
        _title('🔁 ভিডিওর অডিও বদলান',
            'ভিডিওর পুরনো অডিও মুছে আপনার দেওয়া অডিও বসবে। এক্সট্রাক্ট বা AI ডাব করা যেকোনো অডিও এখানে দিতে পারেন।'),
        _fileTile('ধাপ ১: ভিডিও', Icons.movie, rpVideo, () async {
          final p = await _pick(FileType.video);
          if (p != null) setState(() => rpVideo = p);
        }),
        _fileTile('ধাপ ২: নতুন অডিও (যেটা বসাবেন)', Icons.audio_file, rpAudio,
            () async {
          final p = await _pick(FileType.audio);
          if (p != null) setState(() => rpAudio = p);
        }),
        const SizedBox(height: 8),
        _action('ধাপ ৩: অডিও রিপ্লেস করুন', Icons.swap_horiz, () {
          if (rpVideo == null) return _toast('আগে ভিডিও সিলেক্ট করুন');
          if (rpAudio == null) return _toast('আগে নতুন অডিও সিলেক্ট করুন');
          _start('rp', 'অডিও রিপ্লেস', () => _jobReplace(rpVideo!, rpAudio!));
        }),
        const SizedBox(height: 12),
        _result('rp'),
        const Text('📁 সেভ হবে: Internal storage / AudioTool / Replaced_Video',
            style: TextStyle(fontSize: 12)),
      ]);

  @override
  Widget build(BuildContext context) {
    final pages = [_tabExtract, _tabAi, _tabReplace];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vid2MP3'),
        actions: [
          IconButton(
            tooltip: 'লগ',
            icon: const Icon(Icons.bug_report_outlined),
            onPressed: _openLogs,
          ),
        ],
      ),
      body: Column(children: [
        if (busy) _progressCard(),
        Expanded(child: pages[tab]()),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.audiotrack), label: 'এক্সট্রাক্ট'),
          NavigationDestination(icon: Icon(Icons.auto_awesome), label: 'AI ডাব'),
          NavigationDestination(icon: Icon(Icons.swap_horiz), label: 'রিপ্লেস'),
        ],
      ),
    );
  }
}


class LogPage extends StatefulWidget {
  const LogPage({super.key});
  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  final sc = ScrollController();

  @override
  void initState() {
    super.initState();
    Log.tick.addListener(_refresh);
    WidgetsBinding.instance.addPostFrameCallback((_) => _down());
  }

  void _refresh() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _down());
  }

  void _down() {
    if (sc.hasClients) sc.jumpTo(sc.position.maxScrollExtent);
  }

  @override
  void dispose() {
    Log.tick.removeListener(_refresh);
    sc.dispose();
    super.dispose();
  }

  Future<void> _share() async {
    final d = await getTemporaryDirectory();
    final f = File('${d.path}/vid2mp3_log.txt');
    await f.writeAsString(Log.text());
    await Share.shareXFiles([XFile(f.path)]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('📋 লগ'),
        actions: [
          IconButton(
            tooltip: 'কপি',
            icon: const Icon(Icons.copy),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: Log.text()));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('লগ কপি হয়েছে')));
            },
          ),
          IconButton(
              tooltip: 'শেয়ার', icon: const Icon(Icons.share), onPressed: _share),
          IconButton(
              tooltip: 'মুছুন',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => Log.clear()),
        ],
      ),
      body: Column(children: [
        Container(
          width: double.infinity,
          color: Theme.of(context).colorScheme.primaryContainer,
          padding: const EdgeInsets.all(8),
          child: const Text(
              'সমস্যা হলে উপরের কপি/শেয়ার চেপে এই লগ পাঠান। অ্যাপ ক্র্যাশ করলেও লগ সেভ থাকে, আবার খুলে এখানে দেখা যাবে।',
              style: TextStyle(fontSize: 12)),
        ),
        Expanded(
          child: Log.lines.isEmpty
              ? const Center(child: Text('এখনো কোনো লগ নেই'))
              : SingleChildScrollView(
                  controller: sc,
                  padding: const EdgeInsets.all(10),
                  child: SelectableText(Log.recent(),
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                ),
        ),
      ]),
    );
  }
}
