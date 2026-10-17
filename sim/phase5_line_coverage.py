"""Automatic procedural-line coverage from Icarus' own file/line debug opcodes.

The compiler chooses the executable sites (-pfileline=1). Only debug opcodes
for TB files are removed; no RTL statement or data-flow opcode is modified.
trace on / cont are documented VVP commands. This metric excludes continuous
assignments, branch outcomes, expression conditions and signal toggles.
"""
from collections import defaultdict
from pathlib import Path
import re
import subprocess
import threading


def prepare(binary):
    # VVP may mix UTF-8 string literals with Windows-codepage source paths.
    # Latin-1 is a reversible byte mapping; never transcode the executable.
    text=Path(binary).read_bytes().decode('latin-1')
    names=text.split(':file_names ',1)[1].splitlines()[1:]
    files=[re.match(r'\s*"(.*)";',s).group(1).replace('\\\\','/')
           for s in names if re.match(r'\s*"(.*)";',s)]
    executable=defaultdict(set)
    kept=[]
    for row in text.splitlines():
        point=re.search(r'%file_line (\d+) (\d+) ',row)
        if point:
            index,line=map(int,point.groups())
            filename=files[index]
            if '/RTL/' not in filename.replace('\\','/'):
                continue
            executable[Path(filename).name].add(line)
        kept.append(row)
    Path(binary).write_bytes(('\n'.join(kept)+'\n').encode('latin-1'))
    return executable


def collect(vvp,binary,cwd,log,timeout=240):
    hit=defaultdict(set)
    process=subprocess.Popen([str(vvp),'-s',str(binary)],cwd=cwd,
        stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
        text=True,encoding='utf-8',errors='replace',bufsize=1)
    timer=threading.Timer(timeout,process.kill);timer.start()
    transcript=[]
    try:
        process.stdin.write('trace on\ncont\n');process.stdin.flush();process.stdin.close()
        for row in process.stdout:
            for file,line in re.findall(r'([^\s:]+\.v):(\d+):',row):
                if '/RTL/' in file.replace('\\','/'):hit[Path(file).name].add(int(line))
            # Runtime traces can be very large. Retain diagnostics and the final verdict.
            if re.search(r'\b(?:PASS|FAIL|FATAL|TIMEOUT)\b|(?:^|\s)ERROR:',row,re.I):transcript.append(row)
        result=process.wait()
    finally:
        timer.cancel()
        if process.poll() is None:process.kill();process.wait()
        process.stdout.close()
    Path(log).write_text(''.join(transcript),encoding='utf-8')
    if result or not any(re.search(r'\bPASS\b',row) for row in transcript) or any(re.search(r'\b(?:FAIL|FATAL|TIMEOUT)\b|(?:^|\s)ERROR:',row,re.I) for row in transcript):
        raise RuntimeError(f'Traced simulation failed: {log}')
    return hit
