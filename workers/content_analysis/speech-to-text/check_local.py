"""Read-only configuration checks and opt-in native fixtures; never contacts Supabase."""
from __future__ import annotations
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

BASE = Path(__file__).resolve().parent
ROOT = BASE.parents[2]
sys.dont_write_bytecode = True

def check(video: Path | None = None) -> dict:
    from dotenv import dotenv_values
    values = {**dotenv_values(BASE / '.env'), **os.environ}
    def tool(name: str, default: str) -> Path:
        raw = Path(values.get(name) or default).expanduser()
        return (BASE / raw).resolve() if not raw.is_absolute() else raw
    cli = tool('WHISPER_CPP_EXE', 'tools/whisper-cuda/Release/whisper-cli.exe')
    model = tool('WHISPER_CPP_MODEL', 'tools/ggml-small.bin')
    ffmpeg = tool('FFMPEG_EXE', 'tools/ffmpeg.exe')
    tessdata = Path(values.get('TESSDATA_PREFIX') or BASE.parent / 'Tesseract-OCR/tessdata')
    report = {'python': sys.version.split()[0],
      'tools': {'whisper': cli.is_file(), 'model': model.is_file(), 'ffmpeg': ffmpeg.is_file(),
                'english_ocr': (tessdata / 'eng.traineddata').is_file()},
      'dependencies': {'pymupdf': importlib.util.find_spec('pymupdf') is not None},
      'backend': {'private_env_present': (BASE / '.env').is_file(),
        'url_configured': bool(values.get('SUPABASE_URL')) and 'YOUR_PROJECT' not in values.get('SUPABASE_URL',''),
        'service_key_configured': bool(values.get('SUPABASE_SERVICE_ROLE_KEY')) and not values.get('SUPABASE_SERVICE_ROLE_KEY','').startswith('replace-')},
      'hosted_requests_made': 0, 'native': {}}
    app_config = ROOT / 'config/supabase.json'
    app_url = os.getenv('SUPABASE_URL', '')
    if app_config.is_file():
        try: app_url = json.loads(app_config.read_text(encoding='utf-8')).get('SUPABASE_URL', '')
        except (ValueError, OSError): pass
    worker_url = values.get('SUPABASE_URL', '')
    report['backend']['matches_app_project'] = bool(app_url and worker_url) and app_url.rstrip('/') == worker_url.rstrip('/')
    if video is None:
        return report
    import pymupdf
    from skilltrack_speech import pdf_adapter
    from skilltrack_speech.worker import process_one
    from skilltrack_speech.transcriber import WhisperCppTranscriber
    os.environ['TESSDATA_PREFIX'] = str(tessdata)
    sentence = 'SkillTrack helps students manage learning projects and find mentors with practical resources.'
    class LocalGateway:
        def __init__(self, source: Path, kind: str): self.source, self.kind, self.saved = source, kind, None
        def claim(self, _):
            return dict(id='fixture', claim_token='fixture-claim', storage_bucket='mentor-video-files' if self.kind == 'video_transcript' else 'mentor-reading-files',
                storage_path='fixture-owner/' + self.source.name, resource_id='fixture-resource',
                source_file_id='fixture-file', source_version='fixture-version', extraction_type=self.kind)
        def renew(self, *_): return True
        def download(self, _bucket, _path, destination): shutil.copyfile(self.source, destination)
        def complete(self, _id, _token, text, language, segments):
            self.saved = dict(characters=len(text), language=language, segments=len(segments),
                              recognized_fixture='skilltrack' in text.lower() or 'students' in text.lower())
            return bool(text.strip())
        def fail(self, _id, _token, code): self.saved = {'failure_code': code}; return True
    with tempfile.TemporaryDirectory(prefix='skilltrack-native-check-') as temp:
        text_path = Path(temp) / 'selectable.pdf'
        doc = pymupdf.open(); page = doc.new_page(); page.insert_text((50,100), sentence, fontsize=12)
        doc.save(text_path)
        image = page.get_pixmap(dpi=200)
        scan_path = Path(temp) / 'scanned.pdf'
        scan = pymupdf.open(); scan.new_page(width=page.rect.width,height=page.rect.height).insert_image(page.rect, pixmap=image)
        scan.save(scan_path); scan.close(); doc.close()
        engine = WhisperCppTranscriber(str(cli), str(model), str(ffmpeg), timeout_seconds=180,
            language='en', use_gpu=values.get('WHISPER_CPP_USE_GPU','true').lower() in {'true','1','yes'})
        for name, source, kind in [('selectable_pdf',text_path,'pdf_text'),('scanned_pdf_ocr',scan_path,'pdf_text'),('video_transcription',video,'video_transcript')]:
            gateway = LocalGateway(source,kind)
            outcome = process_one(gateway,engine,lease_seconds=900,renew_seconds=1)
            result = {'outcome': outcome, **(gateway.saved or {})}
            if kind == 'pdf_text':
                details = pdf_adapter._module.extract_pdf_text(source,tessdata_dir=tessdata)
                result['page_methods'] = [p.method for p in details.pages]
                result['page_errors'] = len(details.errors)
            report['native'][name] = result
    return report

def main() -> int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--video',type=Path,help='Opt-in native video/PDF/OCR checks using a local speech fixture')
    parser.add_argument('--report',type=Path,help='Save a credential-free JSON report')
    args=parser.parse_args()
    try:
        report=check(args.video)
    except Exception as error:
        print(json.dumps({'error_type':type(error).__name__,'status':'local_check_failed','hosted_requests_made':0}))
        return 1
    content=json.dumps(report,indent=2)
    if args.report: args.report.write_text(content+'\n',encoding='utf-8')
    print(content)
    if args.video and any(r.get('outcome') != 'ready' or not r.get('recognized_fixture') or r.get('page_errors',0) for r in report['native'].values()): return 1
    return 0
if __name__=='__main__': raise SystemExit(main())
