import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from phase5_line_coverage import prepare,collect


class CoverageTests(unittest.TestCase):
    def test_compiler_denominator_and_unexecuted_branch(self):
        iv=shutil.which('iverilog') or os.environ.get('IVERILOG')
        if not iv:self.skipTest('iverilog required')
        vv=Path(iv).with_name('vvp.exe' if os.name=='nt' else 'vvp')
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);(root/'RTL').mkdir()
            source=root/'RTL/fixture.v';binary=root/'f.out'
            source.write_text('module fixture;\nreg flag=0;\ninitial begin\n#1;\nif(flag)\n$display("UNEXECUTED");\nelse $display("PASS");\n$finish;\nend\nendmodule\n')
            subprocess.run([iv,'-g2012','-pfileline=1','-o',str(binary),str(source)],check=True)
            sites=prepare(binary)
            hits=collect(vv,binary,root,root/'trace.log')
            self.assertIn(6,sites['fixture.v'])
            self.assertNotIn(6,hits['fixture.v'])
            self.assertIn(7,hits['fixture.v'])
            self.assertLess(len(hits['fixture.v']),len(sites['fixture.v']))

    def test_trace_run_cannot_hide_failure_behind_pass(self):
        iv=shutil.which('iverilog') or os.environ.get('IVERILOG')
        if not iv:self.skipTest('iverilog required')
        vv=Path(iv).with_name('vvp.exe' if os.name=='nt' else 'vvp')
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);source=root/'f.v';binary=root/'f.out'
            source.write_text('module fixture;initial begin $display("FAIL: deliberate");$display("PASS");$finish;end endmodule')
            subprocess.run([iv,'-g2012','-pfileline=1','-o',str(binary),str(source)],check=True)
            prepare(binary)
            with self.assertRaises(RuntimeError):collect(vv,binary,root,root/'trace.log')


if __name__=='__main__':unittest.main()
