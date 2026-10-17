import 'dart:convert';
import 'dart:io';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Audio Tool',
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
  String? videoPath, dubPath, outPath;
  bool busy = false;
  String status = 'ভিডিও সিলেক্ট করুন';
  String lang = 'bn'; // bn = বাংলা, hi = হিন্দি
  final keyCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      keyCtrl.text = p.getString('groq_key') ?? '';
    });
  }

  String _name(String? p) => p == null ? '—' : p.split('/').last;

  Future<void> pickVideo() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.video);
    if (r?.files.single.path != null) {
      setState(() {
        videoPath = r!.files.single.path;
        outPath = null;
        status = 'ভিডিও রেডি';
      });
    }
  }

  Future<void> pickDub() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.audio);
    if (r?.files.single.path != null) {
      setState(() {
        dubPath = r!.files.single.path;
        outPath = null;
      });
    }
  }

  Future<String> _outFile(String ext) async {
    final dir = (await getExternalStorageDirectory()) ??
        await getApplicationDocumentsDirectory();
    final t = DateTime.now().millisecondsSinceEpoch;
    return '${dir.path}/audio_$t.$ext';
  }

  Future<bool> _ff(List<String> args) async {
    final s = await FFmpegKit.executeWithArguments(args);
    return ReturnCode.isSuccess(await s.getReturnCode());
  }

  Future<void> _run(List<String> args, String out, String doneMsg) async {
    setState(() {
      busy = true;
      status = 'প্রসেস হচ্ছে...';
    });
    final ok = await _ff(args);
    setState(() {
      busy = false;
      if (ok) {
        outPath = out;
        status = doneMsg;
      } else {
        status = 'ব্যর্থ হয়েছে! অন্য ফাইল চেষ্টা করুন';
      }
    });
  }

  // ভিডিও থেকে অডিও এক্সট্রাক্ট (MP3)
  Future<void> extract() async {
    if (videoPath == null) return;
    final out = await _outFile('mp3');
    await _run(
        ['-y', '-i', videoPath!, '-vn', '-c:a', 'libmp3lame', '-b:a', '192k', out],
        out,
        'MP3 এক্সট্রাক্ট সফল ✅');
  }

  // নিজের অডিও দিয়ে ম্যানুয়াল ডাব
  Future<void> dub() async {
    if (videoPath == null || dubPath == null) return;
    final out = await _outFile('mp4');
    await _run([
      '-y', '-i', videoPath!, '-i', dubPath!,
      '-map', '0:v:0', '-map', '1:a:0',
      '-c:v', 'copy', '-c:a', 'aac', '-shortest', out
    ], out, 'ডাবিং সফল ✅');
  }

  // ---------- AI ডাব (ফ্রি সিস্টেম) ----------

  // 1) Speech-to-Text: Groq Whisper (ফ্রি key), যেকোনো ভাষা অটো ডিটেক্ট
  Future<List<Seg>> _transcribe(String audio, String key) async {
    final req = http.MultipartRequest(
        'POST', Uri.parse('https://api.groq.com/openai/v1/audio/transcriptions'));
    req.headers['Authorization'] = 'Bearer $key';
    req.fields['model'] = 'whisper-large-v3';
    req.fields['response_format'] = 'verbose_json';
    req.files.add(await http.MultipartFile.fromPath('file', audio));
    final res = await http.Response.fromStream(await req.send());
    if (res.statusCode != 200) {
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

  // 2) অনুবাদ: Google Translate (ফ্রি, key লাগে না)
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

  // 3) Text-to-Speech: Google TTS (ফ্রি, key লাগে না)
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

  Future<double> _dur(String p) async {
    final s = await FFprobeKit.getMediaInformation(p);
    return double.tryParse(s.getMediaInformation()?.getDuration() ?? '') ?? 0;
  }

  void _st(String m) => setState(() => status = m);

  Future<void> aiDub() async {
    final key = keyCtrl.text.trim();
    if (videoPath == null) return;
    if (key.isEmpty) {
      _st('আগে Groq API key দিন (ফ্রি)');
      return;
    }
    (await SharedPreferences.getInstance()).setString('groq_key', key);
    setState(() {
      busy = true;
      outPath = null;
    });
    try {
      final tmp = await getTemporaryDirectory();
      final id = DateTime.now().millisecondsSinceEpoch;

      _st('১/৪ অডিও বের হচ্ছে...');
      final wav = '${tmp.path}/src_$id.mp3';
      if (!await _ff(['-y', '-i', videoPath!, '-vn', '-ac', '1', '-ar', '16000',
        '-c:a', 'libmp3lame', '-b:a', '48k', wav])) {
        throw 'অডিও এক্সট্রাক্ট ব্যর্থ';
      }

      _st('২/৪ কথা টেক্সটে রূপান্তর হচ্ছে...');
      final segs = await _transcribe(wav, key);
      if (segs.isEmpty) throw 'ভিডিওতে কোনো কথা পাওয়া যায়নি';

      final files = <String>[];
      final used = <Seg>[];
      for (var i = 0; i < segs.length; i++) {
        _st('৩/৪ অনুবাদ ও ভয়েস তৈরি ${i + 1}/${segs.length}');
        final tr = await _translate(segs[i].text, lang);
        if (tr.trim().isEmpty) continue;
        final f = '${tmp.path}/seg_${id}_$i.mp3';
        await _tts(tr, lang, f);
        files.add(f);
        used.add(segs[i]);
      }
      if (files.isEmpty) throw 'ভয়েস তৈরি হয়নি';

      _st('৪/৪ ভিডিওতে বসানো হচ্ছে...');
      final fc = StringBuffer();
      final labels = StringBuffer();
      for (var i = 0; i < files.length; i++) {
        final s = used[i];
        final nextStart =
            i + 1 < used.length ? used[i + 1].start : s.end + 1.0;
        final slot = (nextStart - s.start).clamp(0.5, 1000.0);
        final d = await _dur(files[i]);
        var tempo = d > slot ? d / slot : 1.0;
        if (tempo > 1.8) tempo = 1.8;
        final ms = (s.start * 1000).round();
        final t = tempo > 1.01 ? 'atempo=${tempo.toStringAsFixed(3)},' : '';
        fc.write('[${i + 1}:a]${t}adelay=$ms|$ms[a$i];');
        labels.write('[a$i]');
      }
      fc.write('${labels}amix=inputs=${files.length}:normalize=0[out]');

      final out = await _outFile('mp4');
      final args = <String>['-y', '-i', videoPath!];
      for (final f in files) {
        args.addAll(['-i', f]);
      }
      args.addAll(['-filter_complex', fc.toString(), '-map', '0:v:0',
        '-map', '[out]', '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k', out]);
      if (!await _ff(args)) throw 'ভিডিও মার্জ ব্যর্থ';

      setState(() {
        outPath = out;
        status = 'AI ডাবিং সফল ✅';
      });
    } catch (e) {
      _st('ব্যর্থ: $e');
    } finally {
      setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Audio Extractor & Dub')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.movie),
              title: const Text('ভিডিও'),
              subtitle: Text(_name(videoPath)),
              trailing: FilledButton(
                  onPressed: busy ? null : pickVideo, child: const Text('Select')),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: busy || videoPath == null ? null : extract,
            icon: const Icon(Icons.audiotrack),
            label: const Text('MP3 এক্সট্রাক্ট করুন'),
          ),
          const Divider(height: 32),
          const Text('🤖 AI অটো ডাব (ফ্রি)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          TextField(
            controller: keyCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Groq API Key (ফ্রি)',
              helperText: 'console.groq.com/keys থেকে ফ্রিতে নিন',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'bn', label: Text('বাংলা')),
              ButtonSegment(value: 'hi', label: Text('हिन्दी')),
            ],
            selected: {lang},
            onSelectionChanged: busy ? null : (s) => setState(() => lang = s.first),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: busy || videoPath == null ? null : aiDub,
            icon: const Icon(Icons.auto_awesome),
            label: const Text('AI দিয়ে ডাব করুন'),
          ),
          const Divider(height: 32),
          const Text('🎙️ নিজের অডিও দিয়ে ডাব',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.mic),
              title: const Text('ডাব অডিও'),
              subtitle: Text(_name(dubPath)),
              trailing: OutlinedButton(
                  onPressed: busy ? null : pickDub, child: const Text('Select')),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: busy || videoPath == null || dubPath == null ? null : dub,
            icon: const Icon(Icons.record_voice_over),
            label: const Text('অডিও রিপ্লেস করুন'),
          ),
          const SizedBox(height: 24),
          if (busy) const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Text(status, textAlign: TextAlign.center),
          if (outPath != null) ...[
            const SizedBox(height: 8),
            SelectableText(outPath!,
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 11)),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => Share.shareXFiles([XFile(outPath!)]),
              icon: const Icon(Icons.share),
              label: const Text('Share / Save'),
            ),
          ],
        ],
      ),
    );
  }
}
