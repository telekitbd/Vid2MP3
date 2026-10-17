import 'dart:io';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

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

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  String? videoPath, dubPath, outPath;
  bool busy = false;
  String status = 'ভিডিও সিলেক্ট করুন';

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

  Future<void> _run(List<String> args, String out, String doneMsg) async {
    setState(() {
      busy = true;
      status = 'প্রসেস হচ্ছে...';
    });
    final session = await FFmpegKit.executeWithArguments(args);
    final code = await session.getReturnCode();
    setState(() {
      busy = false;
      if (ReturnCode.isSuccess(code)) {
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

  // ভিডিওর অডিও বদলে নতুন অডিও (ডাব) বসানো
  Future<void> dub() async {
    if (videoPath == null || dubPath == null) return;
    final out = await _outFile('mp4');
    await _run([
      '-y', '-i', videoPath!, '-i', dubPath!,
      '-map', '0:v:0', '-map', '1:a:0',
      '-c:v', 'copy', '-c:a', 'aac', '-shortest', out
    ], out, 'ডাবিং সফল ✅');
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
            label: const Text('অডিও এক্সট্রাক্ট করুন'),
          ),
          const Divider(height: 32),
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
            label: const Text('ডাব করুন (অডিও রিপ্লেস)'),
          ),
          const SizedBox(height: 24),
          if (busy) const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Text(status, textAlign: TextAlign.center),
          if (outPath != null) ...[
            const SizedBox(height: 8),
            SelectableText(outPath!, textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11)),
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
