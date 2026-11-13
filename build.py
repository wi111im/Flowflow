#!/usr/bin/env python3
"""Build with the Xcode command line tools. No external package manager needed."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import os

ROOT = Path(__file__).resolve().parent
WORK = ROOT / 'work'
APP = ROOT / 'Flowflow.app'
RESOURCES = APP / 'Contents/Resources'
MACOS = APP / 'Contents/MacOS'
WORK.mkdir(exist_ok=True)
if APP.exists():
    shutil.rmtree(APP)
RESOURCES.mkdir(parents=True, exist_ok=True)
MACOS.mkdir(parents=True, exist_ok=True)
adapter = ROOT / 'Vendor/mediaremote-adapter'
framework = RESOURCES / 'MediaRemoteAdapter.framework'
framework.mkdir(exist_ok=True)
(framework / 'Resources').mkdir(exist_ok=True)
sources = [str(x) for folder in ['adapter', 'private', 'utility']
           for x in sorted((adapter / 'src' / folder).glob('*.m'))]
subprocess.run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-fvisibility=default',
    '-mmacosx-version-min=15.0', '-I' + str(adapter / 'include'), '-I' + str(adapter / 'src'),
    '-framework', 'Foundation', '-framework', 'AppKit', '-framework', 'UniformTypeIdentifiers',
    *sources, '-o', str(framework / 'MediaRemoteAdapter')], check=True)
(framework / 'Resources/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'MediaRemoteAdapter', 'CFBundleIdentifier': 'local.flowflow.MediaRemoteAdapter',
    'CFBundlePackageType': 'FMWK', 'CFBundleVersion': '1'}))
shutil.copy2(adapter / 'bin/mediaremote-adapter.pl', RESOURCES)
shutil.copy2(adapter / 'LICENSE', RESOURCES / 'LICENSE-mediaremote-adapter.txt')
shutil.copy2(ROOT / 'LICENSE', RESOURCES / 'LICENSE-GPL-3.0.txt')
shutil.copytree(ROOT / 'Resources', RESOURCES, dirs_exist_ok=True)
subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-O', '-parse-as-library',
    '-target', 'arm64-apple-macos15.0', '-lz', '-module-cache-path', str(WORK / 'swift-cache'),
    *[str(x) for x in sorted((ROOT / 'Sources').glob('*.swift'))],
    '-o', str(MACOS / 'Flowflow')], check=True)
subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-O', '-target', 'arm64-apple-macos15.0', '-framework', 'AppKit', str(ROOT / 'Helper/Monitor.swift'), '-o', str(MACOS / 'FlowflowMonitor')], check=True)
(APP / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleName': 'Flowflow', 'CFBundleDisplayName': 'Flowflow',
    'CFBundleIdentifier': 'local.flowflow.desktop', 'CFBundleExecutable': 'Flowflow',
    'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1.0.113',
    'CFBundleVersion': '114', 'LSMinimumSystemVersion': '15.0',
    'LSUIElement': True, 'NSHighResolutionCapable': True,
    'CFBundleDevelopmentRegion': 'zh-Hans', 'CFBundleLocalizations': ['zh-Hans'],
    'NSHumanReadableCopyright': 'Includes MeloX (GPL-3.0) and MediaRemote Adapter (BSD-3-Clause).',
}))
identity_listing = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'],
                                  capture_output=True, text=True, check=True).stdout
local_identity = 'Flowflow Local Code Signing'
signing_identity = os.environ.get('FLOWFLOW_SIGNING_IDENTITY') or (local_identity if f'"{local_identity}"' in identity_listing else '-')
print(f'Code signing identity: {signing_identity}', flush=True)
for attempt in range(3):
    for attribute in ['com.apple.FinderInfo', 'com.apple.ResourceFork']:
        subprocess.run(['xattr', '-rd', attribute, str(APP)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    signed = subprocess.run(['codesign', '--force', '--deep', '--sign', signing_identity, str(APP)])
    if signed.returncode == 0:
        verified = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(APP)])
        if verified.returncode == 0:
            break
else:
    raise RuntimeError("App signature did not pass verification after attribute cleanup")
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(APP)], check=True)
subprocess.run([str(MACOS / 'Flowflow'), '--self-test'], check=True)
print(APP)
