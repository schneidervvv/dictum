#!/usr/bin/env python3
"""Exercise the production relaunch callback and termination in an isolated AppKit process."""

from pathlib import Path
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parent.parent
    products = root / ".build/DerivedData/Build/Products/Debug"
    frameworks = products / "dictum Dev.app/Contents/Frameworks"
    source = (root / "TypeWhisper/Views/GeneralSettingsView.swift").read_text()
    callback = source[source.index("private func completeApplicationRelaunch("):source.index("struct GeneralSettingsView:")]
    fixture = (root / "scripts/fixtures/TerminationRelaunchProbe.swift").read_text()
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    with tempfile.TemporaryDirectory(prefix="dictum-termination-") as temporary:
        directory = Path(temporary)
        main_source = directory / "main.swift"
        main_source.write_text("import AppKit\nimport TypeWhisperPluginSDK\n" + callback + fixture)
        executable = directory / "termination-probe"
        subprocess.run([
            "xcrun", "--sdk", "macosx", "swiftc", "-sdk", sdk,
            "-swift-version", "6", "-I", str(products), "-F", str(frameworks),
            "-framework", "TypeWhisperPluginSDK", "-Xlinker", "-rpath", "-Xlinker", str(frameworks),
            str(main_source), str(root / "TypeWhisper/Dictum/TerminationPreparation.swift"),
            "-o", str(executable),
        ], check=True)
        failures = []
        for mode in ("idle", "active"):
            process = subprocess.Popen([str(executable), mode], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            try:
                output, _ = process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                output, _ = process.communicate()
                failures.append(f"{mode}: termination timed out")
            events = output.decode().splitlines()
            print(f"{mode}: pid={process.pid}, exit={process.returncode}, events={events}", flush=True)
            expected = ["termination requested", "termination replied", "will terminate"]
            if mode == "active":
                expected = ["inference started", "termination requested", "inference ended", "termination replied", "will terminate"]
            if process.returncode != 0 or events != expected:
                failures.append(f"{mode}: expected {expected}")
        if failures:
            raise SystemExit("\n".join(failures))


if __name__ == "__main__":
    main()
