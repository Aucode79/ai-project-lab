"""Render captioned contact sheets, and probe the final media when present."""
import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1] / "lesson01"
edit = json.loads((root / "edit.json").read_text(encoding="utf-8"))
ids = ["agent", "model", "tools", "observation", "loop", "closure", "reroute", "collect", "experience"]
video = root / "lesson01-agent.mp4"
process_flags = getattr(subprocess, "CREATE_NO_WINDOW", 0) | getattr(subprocess, "ABOVE_NORMAL_PRIORITY_CLASS", 0)
images = []
for ident in ids:
    shot = next(s for s in edit["shots"] if s["id"] == ident)
    time = shot["start"] + shot["duration"]*0.5
    output = root / ("qc_"+ident+".jpg")
    if video.exists():
        command = ["ffmpeg", "-y", "-ss", str(time), "-i", str(video), "-frames:v", "1", str(output)]
    else:
        command = ["ffmpeg", "-y", "-i", str(root / ("preview_"+ident+".jpg")),
            "-vf", f"setpts=PTS+{time}/TB,ass=captions.ass", "-frames:v", "1", str(output)]
    subprocess.run(command, cwd=root, check=True, capture_output=True, creationflags=process_flags)
    images.append(output)
command = ["ffmpeg", "-y"]
for image in images: command += ["-i", str(image)]
graph = ";".join(f"[{i}:v]scale=640:360[v{i}]" for i in range(9)) + ";"
graph += "".join(f"[v{i}]" for i in range(9))
graph += "xstack=inputs=9:layout=0_0|640_0|1280_0|0_360|640_360|1280_360|0_720|640_720|1280_720[v]"
command += ["-filter_complex", graph, "-map", "[v]", "-frames:v", "1", str(root / "contact-sheet.jpg")]
subprocess.run(command, cwd=root, check=True, capture_output=True, creationflags=process_flags)
if video.exists():
    probe = subprocess.check_output(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(video)], creationflags=process_flags)
    report = json.loads(probe)
    stream = next(s for s in report["streams"] if s["codec_type"] == "video")
    audio_stream = next(s for s in report["streams"] if s["codec_type"] == "audio")
    assert audio_stream["sample_rate"] == "48000"
    assert (stream["width"],stream["height"],stream["r_frame_rate"]) == (1920,1080,"25/1")
    assert abs(float(report["format"]["duration"])-edit["duration"]) < 0.1
    report["renderFrameCount"] = len(list((root / "frames").glob("frame_*.jpg")))
    assert report["renderFrameCount"] == edit["frames"]
    (root / "media-verification.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    result = subprocess.run(["ffmpeg", "-i", str(video), "-af", "volumedetect", "-vn", "-sn", "-f", "null", "-"], capture_output=True, creationflags=process_flags)
    (root / "audio-verification.txt").write_text(result.stderr.decode("utf-8",errors="replace"), encoding="utf-8")
print("CONTACT SHEET READY", "FINAL MEDIA VERIFIED" if video.exists() else "PREVIEW")
