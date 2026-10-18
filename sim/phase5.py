"""CPU-free phase-5 regression, functional closure and native XSim coverage.

Run: python sim/phase5.py [--native] [--report docs/阶段5-覆盖率报告.md]
All detailed outputs live under build/phase5 (gitignored).
"""
import argparse
from collections import Counter
from collections import defaultdict
from phase5_line_coverage import prepare as prepare_trace, collect as collect_trace
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
NEW_TOPS = ['tb_phase5_ahb', 'tb_phase5_sram', 'tb_phase5_integration']
UNIT_TOPS = ['tb_axi_to_apb','tb_axi_sram','tb_axi_ic','tb_fifo_arbiter',
             'tb_dma_engine','tb_dma_self','tb_dma','tb_dma_ic','tb_fir_core_contract',
             'tb_fir_core','tb_fir','tb_uart_echo','tb_uart_apb_edges']
REQUIRED = {
    'integration': ['fir_dma_golden_338','parallel_cpu_dma','dma_4k_split',
                    'six_channels','dma_read_decerr','dma_write_decerr',
                    'zero_length','decode_errors','reset_active_recovery','dma_config_bursts'],
    'apb': ['halfword_strobe','simultaneous_addresses','timeout_all_beats','early_error_drain'],
    'arbiter': ['stalled_winner','round_robin_all'],
    'fifo': ['non_power_two_wrap','simultaneous_read_write'],
    'ahb': ['burst.%d'%n for n in range(8)]+['size.%d'%n for n in range(4)]+
           ['wait','busy','error_first','error_complete','size_burst_matrix','invalid_alignment_size'],
    'sram': ['size_burst_matrix','max_lengths','byte_lanes_zero_strobe','unaligned_incr',
             'cross_4k_no_side_effect','unsupported_and_out_of_range','last_word']+
            [f'{d}.size.{s}' for d in ['aw','ar'] for s in range(4)]+
            [f'{d}.burst.{b}' for d in ['aw','ar'] for b in range(4)]+
            [f'{d}.aligned.{b}' for d in ['aw','ar'] for b in range(2)]+
            [f'{d}.resp.{b}' for d in ['b','r'] for b in [0,2,3]]+['stall.b','stall.r'],
    'dma': ['aw.burst.0','aw.burst.1','ar.burst.0','ar.burst.1','b.resp.0','b.resp.3',
            'r.resp.0','r.resp.3','aw.size.2','ar.size.2'],
    'fir': ['aw.burst.0','aw.burst.1','ar.burst.0','b.resp.0','r.resp.0'],
}


def run(cmd, cwd, log, timeout=240, require_pass=False):
    result = subprocess.run([str(x) for x in cmd], cwd=cwd, capture_output=True,
                            text=True, encoding='utf-8', errors='replace', timeout=timeout)
    text = result.stdout + result.stderr
    log.write_text(text, encoding='utf-8')
    if result.returncode or (require_pass and
            (not re.search(r'\bPASS\b',text) or re.search(r'\b(?:FAIL|TIMEOUT|FATAL)\b|(?:^|\s)ERROR:',text,re.I))):
        raise RuntimeError(f'Command failed; see {log}\n{text[-3000:]}')
    return text


def executable(name, default):
    return shutil.which(name) or (str(default) if Path(default).is_file() else None)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--native',action='store_true',help='Run XSim covergroups and statement/branch/condition/toggle coverage')
    ap.add_argument('--line-coverage',action='store_true',help='Measure compiler-instrumented procedural lines')
    ap.add_argument('--xilinx-bin',default=os.environ.get('XILINX_BIN',r'D:\apps\vivado\Vivado\2026.1\Vivado\bin'))
    ap.add_argument('--seeds',default='1,7,23')
    ap.add_argument('--report',type=Path)
    ap.add_argument('--work-dir',type=Path,help='New staging directory; use an ASCII path for XSim')
    args=ap.parse_args()
    out=ROOT/'build/phase5';out.mkdir(parents=True,exist_ok=True)
    if args.work_dir:
        args.work_dir.mkdir(parents=True,exist_ok=False)
        work=args.work_dir.resolve()
    else:
        work=Path(tempfile.mkdtemp(prefix='soc_phase5_'))
    if args.native and not str(work).isascii():
        ap.error('XSim needs an ASCII path: pass --work-dir C:/Windows/Temp/a-new-directory')
    # Stage sources under ASCII paths for vendor tools that reject Unicode paths.
    (work/'RTL').mkdir();(work/'TB').mkdir()
    for src in sorted((ROOT/'RTL').glob('*.v')):
        if src.name!='soc_top.v': shutil.copy2(src,work/'RTL'/src.name)
    helpers=[ROOT/'TB'/n for n in ['axi_mem_model.v','axi_protocol_checker.v','axi_id_contract_check.v']]
    helpers+=list((ROOT/'TB').glob('phase5_*'))
    tops=NEW_TOPS+UNIT_TOPS
    for src in helpers+[ROOT/'TB'/(t+'.v') for t in tops]:shutil.copy2(src,work/'TB'/src.name)
    run([sys.executable,ROOT/'fir/fir_coeff.py','--outdir',work/'fir'],ROOT,out/'vectors.log')
    iv=executable('iverilog',r'E:\apps\iverilog\iverilog\bin\iverilog.exe')
    if not iv:ap.error('iverilog not found')
    vv=Path(iv).with_name('vvp.exe' if os.name=='nt' else 'vvp')
    sources=sorted((work/'RTL').glob('*.v'))+[work/'TB'/p.name for p in helpers]
    tests=[];events=Counter();line_executable=defaultdict(set);line_hit=defaultdict(set)
    def collect(log):
        for scope,key in re.findall(r'^COV\|([^|\r\n]+)\|([^\r\n]+)',log,re.M):events[(scope,key.strip())]+=1
    seeds=[int(n) for n in args.seeds.split(',')]
    for top in tops:
        binary=work/(top+'.out')
        run([iv,'-g2012','-s',top,'-o',binary,*sources,work/'TB'/(top+'.v')],work,out/(top+'.compile.log'))
        for seed in seeds if top=='tb_phase5_integration' else [seeds[0]]:
            text=run([vv,binary,f'+seed={seed}'],work,out/f'{top}.{seed}.log',require_pass=True)
            collect(text);tests.append({'top':top,'seed':seed,'status':'PASS'})
        print(f'PASS {top}',flush=True)
        if args.line_coverage:
            traced=work/(top+'.trace.out')
            run([iv,'-g2012','-pfileline=1','-s',top,'-o',traced,*sources,work/'TB'/(top+'.v')],work,out/(top+'.trace.compile.log'))
            for file,points in prepare_trace(traced).items():line_executable[file].update(points)
            for file,points in collect_trace(vv,traced,work,out/(top+'.trace.log')).items():line_hit[file].update(points)
            print(f'LINE COVERAGE {top}',flush=True)
    native_status='not_run';native_dir=None;native_covergroups=[]
    if args.native:
        native_dir=out/'native';native_dir.mkdir(exist_ok=True)
        xb=Path(args.xilinx_bin)
        def vendor(tool,*argv,log,require_pass=False):
            return run([xb/(tool+'.bat'),*argv],work,native_dir/log,timeout=600,require_pass=require_pass)
        svsources=[*sorted((work/'RTL').glob('*.v')),*sorted((work/'TB').glob('*'))]
        vendor('xvlog','--sv','-d','PHASE5_NATIVE_COVERAGE',*svsources,log='compile.log')
        (work/'coverage.tcl').write_text('run all\nwrite_xsim_coverage\nquit\n')
        covdir=work/'cov';covdir.mkdir()
        for top in tops:
            snapshot=top+'_cov'
            vendor('xelab',top,'-s',snapshot,'--cc_type','sbct','--cov_db_dir',covdir.as_posix(),
                   '--cov_db_name',top,log=top+'.elaborate.log')
            text=vendor('xsim',snapshot,'--onfinish','stop','--tclbatch','coverage.tcl',
                        '--cov_db_dir',covdir.as_posix(),'--cov_db_name',top,log=top+'.run.log',require_pass=True)
            collect(text)
            for scope,percent in re.findall(r'NATIVE_COV\|([^|\r\n]+)\|([0-9.]+)',text):
                native_covergroups.append({'top':top,'scope':scope,'percent':float(percent)})
            print(f'NATIVE PASS {top}',flush=True)
        try:
            vendor('xcrg','-cov_db_dir',covdir.as_posix(),'-report_dir',(work/'native_report').as_posix(),
                   '-report_format','all',log='xcrg.log')
            shutil.copytree(work/'native_report',native_dir/'report',dirs_exist_ok=True)
            native_status='measured'
        except RuntimeError:
            reason=(native_dir/'xcrg.log').read_text(encoding='utf-8')
            if 'license' not in reason.lower():raise
            native_status='databases_collected_report_blocked_by_BASIC_license'
            print('Native databases saved; xcrg reporting requires PRO license.',flush=True)
        shutil.copytree(covdir,native_dir/'databases',dirs_exist_ok=True)
    required=sum(len(v) for v in REQUIRED.values())
    missing=[f'{scope}|{key}' for scope,keys in REQUIRED.items() for key in keys if not events[(scope,key)]]
    fingerprint=hashlib.sha256()
    for p in sorted(list((work/'RTL').glob('*.v'))+list((work/'TB').glob('*'))):
        if p.is_file():fingerprint.update(p.name.encode());fingerprint.update(p.read_bytes())
    data={'source_sha256':fingerprint.hexdigest(),'tests':tests,'native_coverage':native_status,
          'required_bins':required,'hit_bins':required-len(missing),'missing_bins':missing,
          'native_covergroups':native_covergroups,
          'events':{s+'|'+k:v for (s,k),v in sorted(events.items())},'work_dir':str(work),
          'procedural_line_coverage':{f:{'hit':len(line_hit[f]&points),'total':len(points),
             'missing':sorted(points-line_hit[f])} for f,points in sorted(line_executable.items())}}
    (out/'summary.json').write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf-8')
    lines=['# 阶段5验证与覆盖率报告','',f'- 源码摘要 SHA-256：`{data["source_sha256"]}`',
           f'- Icarus 回归：{len(tests)} 次运行全部通过；集成等待配置种子：{args.seeds}。',
           f'- 验证计划必达 bins：{data["hit_bins"]}/{required}（{100*data["hit_bins"]/required:.2f}%）。',
           f'- XSim 原生 covergroup 和代码覆盖率：{native_status}。',
           '- 详细日志、JSON 和可用的原生数据库/报告：`build/phase5/`。',
           '- 功能计划覆盖与代码覆盖分别统计，测试通过不等于覆盖率达到 100%。','',
           '| 范围 | 命中 / 必达 | 未覆盖 |','|---|---:|---|']
    for s,keys in REQUIRED.items():
        gaps=[k for k in keys if not events[(s,k)]]
        lines.append(f'| {s} | {len(keys)-len(gaps)}/{len(keys)} | '+(', '.join(gaps) or '无')+' |')
    if native_covergroups:
        lines+=['','## 原生 covergroup 诊断结果','',
                '以下由 XSim `get_inst_coverage()` 实测，包含通用模型中的不支持类型及交叉组合，不与必达矩阵混算。','',
                '| Top | 实例范围 | 原生覆盖率 |','|---|---|---:|']
        for row in native_covergroups:lines.append(f'| {row["top"]} | {row["scope"]} | {row["percent"]:.3f}% |')
    if line_executable:
        lines+=['','## 自动代码覆盖：Icarus 可执行过程语句行','',
                '| RTL 文件 | 已执行 / 可执行行 | 覆盖率 | 未覆盖行 |','|---|---:|---:|---|']
        for file,record in data['procedural_line_coverage'].items():
            lines.append(f'| {file} | {record["hit"]}/{record["total"]} | {100*record["hit"]/record["total"]:.2f}% | '+', '.join(map(str,record['missing']))+' |')
        hit_count=sum(v['hit'] for v in data['procedural_line_coverage'].values())
        total_count=sum(v['total'] for v in data['procedural_line_coverage'].values())
        lines+=['',f'合计：{hit_count}/{total_count}（{100*hit_count/total_count:.2f}%）。分母由 Icarus 编译器调试指令自动确定，不是人工选取源代码行。',
                '该指标只统计已展开配置的过程语句行；连续赋值、分支两侧、条件组合和信号翻转不在此指标内。'
                'RTL 未插入或改写功能语句，仅去掉编译产物中的 TB 调试指令以降低跟踪量。',
                '[Icarus 跟踪命令官方说明](https://steveicarus.github.io/iverilog/usage/vvp_debug.html)。']
        lines+=['','剩余缺口保留在上表，未从分母扣除。AHB/DMA 寄存器状态机的 default 恢复分支需要非法状态注入；'
                'DMA 的 ID 契约报错分支需要上游引擎违反契约。当前没有用强制破坏 RTL 状态或 ID 的方式凑覆盖。']
    lines+=['','## 复现','', '```powershell','python sim/phase5.py --line-coverage --native --work-dir C:/Windows/Temp/soc_phase5_new_run --report docs/阶段5-覆盖率报告.md','```','',
            '## 范围与限制','',
            '集成测试独立实例化 FIR、DMA、AXI 互连、SRAM 和 UART/APB，未实例化 CPU 或 soc_top。'
            'FIR 黄金模型通过文件输入，338 项端到端结果逐项比较；CPU AXI BFM 与 DMA 争用真实互连。',
            'AHB 的 BUSY/IDLE 不应发起传输；未对齐 AHB 属于非法输入并返回两周期 ERROR；'
            'SRAM 的未对齐 AXI 传输则按 AXI 地址对齐规则处理。',
            '原生通用 covergroup 还包含部分端口不支持的类型和交叉组合；其未命中项保留为诊断信息，'
            '不能用计划必达 bins 的比例替代原生覆盖率。未做 CPU 软件覆盖、形式证明、综合或上板。','']
    report=args.report or out/'report.md'
    if not report.is_absolute():report=ROOT/report
    report.parent.mkdir(parents=True,exist_ok=True);report.write_text('\n'.join(lines),encoding='utf-8')
    print(f'Functional closure: {data["hit_bins"]}/{required}; missing: {missing}',flush=True)
    print(f'Report: {report}')
    if missing: return 1
    return 0


if __name__=='__main__':
    try:sys.exit(main())
    except (RuntimeError,subprocess.TimeoutExpired) as exc:print(exc,file=sys.stderr);sys.exit(1)
