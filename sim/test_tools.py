"""Regression tests for the firmware converter and FIR reference tools."""
import contextlib
import io
import math
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'fir'))
sys.path.insert(0, str(ROOT / 'sw'))
import fir_coeff
import fir_fixedpoint_analysis
import build


class ToolTests(unittest.TestCase):
    def test_even_and_odd_folding_bounds_match_direct_worst_case(self):
        for taps in (81, 82):
            report = fir_fixedpoint_analysis.width_report([-32768] * taps, 16, 16)
            self.assertEqual(report['sym_worst_any'], taps * (1 << 30))
            self.assertEqual(report['sym_worst_this'], taps * (1 << 30))
            self.assertEqual(report['sym_center'], -32768 if taps % 2 else 0)

    def test_judge_rrmse_definition_and_zero_reference(self):
        self.assertAlmostEqual(fir_coeff.relative_rmse([16384, -16384], [0.5, -0.5]), 0)
        self.assertAlmostEqual(fir_coeff.relative_rmse([16384, 16384], [1.0, 1.0]), 0.5)
        self.assertEqual(fir_coeff.relative_rmse([0], [0.0]), 0)
        self.assertTrue(math.isinf(fir_coeff.relative_rmse([1], [0.0])))
        with self.assertRaises(ValueError):
            fir_coeff.relative_rmse([1, 2], [1.0])

    def test_generated_header_is_valid_verilog(self):
        iv = os.environ.get('IVERILOG') or shutil.which('iverilog')
        if not iv:
            self.skipTest('set IVERILOG to run header compilation test')
        vv = str(Path(iv).with_name('vvp.exe' if os.name == 'nt' else 'vvp'))
        with tempfile.TemporaryDirectory() as td:
            header = Path(td)/'coeffs.vh'
            fir_coeff.write_coeffs_vh(header, [20, -9])
            source, out = Path(td)/'fixture.v', Path(td)/'fixture.out'
            source.write_text('module fixture;\n'+header.read_text(encoding='utf-8')+
                '\ninitial begin if(H0!=20 || H1!=-9) $fatal(1,"coefficient sign"); $finish; end\nendmodule\n', encoding='utf-8')
            subprocess.run([iv,'-g2012','-o',str(out),str(source)],check=True)
            subprocess.run([vv,str(out)],check=True,stdout=subprocess.DEVNULL)

    def test_fallback_cutoff_is_relative_to_nyquist(self):
        old = fir_coeff.HAS_SCIPY
        try:
            fir_coeff.HAS_SCIPY = False
            h = fir_coeff.design_lowpass(81, 0.12)
        finally:
            fir_coeff.HAS_SCIPY = old
        response = abs(sum(v * complex(math.cos(math.pi * 0.12 * n),
                                       -math.sin(math.pi * 0.12 * n))
                           for n, v in enumerate(h)))
        self.assertAlmostEqual(sum(h), 1.0, places=12)
        self.assertAlmostEqual(response, 0.5, delta=0.02)
        if old:
            ref = fir_coeff.design_lowpass(81, 0.12)
            self.assertLess(max(abs(a-b) for a,b in zip(h,ref)), 1e-12)

    def test_binary_converter_little_endian_and_padding(self):
        with tempfile.TemporaryDirectory() as td:
            src, dst = Path(td)/'f.bin', Path(td)/'f.hex'
            src.write_bytes(bytes([0x12, 0x34, 0x56, 0x78, 0xAB]))
            self.assertEqual(build.bin_to_word_hex(src, dst), 2)
            self.assertEqual(dst.read_text().splitlines(), ['78563412', '000000AB'])

    def test_reference_checker_rejects_truncation_and_wrong_values(self):
        with tempfile.TemporaryDirectory() as td:
            script = str(ROOT/'fir/fir_coeff.py')
            base = [sys.executable, script, '--outdir', td]
            subprocess.run(base, check=True, stdout=subprocess.DEVNULL)
            exp = (Path(td)/'exp.hex').read_text().splitlines()
            got = Path(td)/'got.hex'
            def check(lines):
                got.write_text('\n'.join(lines)+'\n')
                return subprocess.run(base+['--check',str(got)],
                                      stdout=subprocess.DEVNULL).returncode
            self.assertEqual(check(['0000']+exp), 0)
            self.assertNotEqual(check(['0001']+exp), 0)
            self.assertNotEqual(check(['0000']+exp[:-1]), 0)
            wrong = exp.copy()
            wrong[20] = '1234' if wrong[20] != '1234' else '5678'
            self.assertNotEqual(check(['0000']+wrong), 0)


if __name__ == '__main__':
    unittest.main()
