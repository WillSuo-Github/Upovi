#!/usr/bin/env python3
"""Embed checksum-pinned mas binaries without running their installers or shell wrappers."""
import hashlib, pathlib, platform, shutil, subprocess, sys, urllib.request
root=pathlib.Path(__file__).resolve().parent.parent
app=pathlib.Path(sys.argv[1]);identity=sys.argv[2]
checks={'arm64':'bc218a854c85d9e1c95496a96b26287bb66056b95688b90f91d04fa62ed21b75','x86_64':'9bca1de1fb6ea19c9e0b9d7b7c85249020c9ed65a9d434c2ef40896a2f3395f9'}
cache=root/'.build/upovi-vendor/mas-7.0.0';cache.mkdir(parents=True,exist_ok=True)
binaries=[]
for arch,digest in checks.items():
 pkg=cache/(arch+'.pkg')
 if not pkg.exists():
  data=urllib.request.urlopen('https://github.com/mas-cli/mas/releases/download/v7.0.0/mas-7.0.0-'+arch+'.pkg',timeout=60).read()
  assert hashlib.sha256(data).hexdigest()==digest
  pkg.write_bytes(data)
 assert hashlib.sha256(pkg.read_bytes()).hexdigest()==digest,'Vendor package checksum mismatch'
 expanded=cache/(arch+'-expanded')
 if expanded.exists():shutil.rmtree(expanded)
 subprocess.run(['/usr/sbin/pkgutil','--expand-full',str(pkg),str(expanded)],check=True)
 binaries.append(str(expanded/'mas.pkg/Payload/usr/local/opt/mas/libexec/bin/mas'))
helper=app/'Contents/MacOS/UpoviStoreBridge'
subprocess.run(['/usr/bin/lipo','-create']+binaries+['-output',str(helper)],check=True)
helper.chmod(0o755)
args=['codesign','--force','--identifier','app.upovi.StoreBridge','--sign',identity]
if identity!='-':args+=['--options','runtime','--timestamp']
subprocess.run(args+[str(helper)],check=True)
subprocess.run(['codesign','--verify','--strict','--all-architectures',str(helper)],check=True)
shutil.copyfile(root/'Vendor/mas-LICENSE',app/'Contents/Resources/mas-LICENSE')

shutil.copytree(root/'Vendor/mas-dependency-licenses',app/'Contents/Resources/mas-dependency-licenses',dirs_exist_ok=True)
