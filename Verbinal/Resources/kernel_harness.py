"""
Kernel Harness — Python execution subprocess for Verbinal.

Protocol: reads JSON requests from stdin, writes JSON responses to stdout.
Each response is terminated by a sentinel line so the host can split messages.

Requests:  {"type": "execute", "code": "...", "exec_count": N}
           {"type": "quit"}

Responses: {"type": "stream", "name": "stdout"|"stderr", "text": "..."}
           {"type": "execute_result", "data": {"text/plain": "..."}, "exec_count": N}
           {"type": "display_data", "data": {"image/png": "base64...", "text/plain": "..."}}
           {"type": "error", "ename": "...", "evalue": "...", "traceback": [...]}
           {"type": "status", "state": "idle"|"busy"}
           {"type": "execute_reply", "exec_count": N, "success": true|false}

Sentinel: \\x04__CANFAR_EXEC_BOUNDARY__\\x04
"""

import sys
import io
import json
import traceback
import base64

SENTINEL = "\x04__CANFAR_EXEC_BOUNDARY__\x04"

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stdin, "reconfigure"):
    sys.stdin.reconfigure(encoding="utf-8")


def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def send_boundary():
    sys.stdout.write(SENTINEL + "\n")
    sys.stdout.flush()


def send_status(state):
    send({"type": "status", "state": state})


_user_ns = {"__name__": "__main__", "__builtins__": __builtins__}

try:
    import matplotlib
    matplotlib.use("Agg")
except ImportError:
    pass


def _capture_display_data(obj):
    try:
        import matplotlib.pyplot as plt
        from matplotlib.figure import Figure
        if isinstance(obj, Figure):
            buf = io.BytesIO()
            obj.savefig(buf, format="png", bbox_inches="tight")
            buf.seek(0)
            b64 = base64.b64encode(buf.read()).decode("ascii")
            plt.close(obj)
            return {"image/png": b64, "text/plain": repr(obj)}
    except ImportError:
        pass
    return None


def _handle_magic(line):
    import subprocess as _sp
    if line.startswith("%pip ") or line.startswith("!pip "):
        args = line.split(None, 1)[1]
        cmd = [sys.executable, "-m", "pip"] + args.split()
        try:
            result = _sp.run(cmd, capture_output=True, text=True, timeout=300)
            outputs = []
            if result.stdout:
                outputs.append({"type": "stream", "name": "stdout", "text": result.stdout})
            if result.stderr:
                outputs.append({"type": "stream", "name": "stderr", "text": result.stderr})
            return outputs
        except Exception as e:
            return [{"type": "error", "ename": type(e).__name__, "evalue": str(e), "traceback": [str(e)]}]

    if line.startswith("!"):
        shell_cmd = line[1:].strip()
        try:
            proc = _sp.Popen(shell_cmd, shell=True, stdout=_sp.PIPE, stderr=_sp.STDOUT, text=True)
            collected = []
            for out_line in proc.stdout:
                collected.append(out_line)
            proc.wait(timeout=120)
            text = "".join(collected)
            outputs = []
            if text:
                outputs.append({"type": "stream", "name": "stdout", "text": text})
            return outputs
        except Exception as e:
            return [{"type": "error", "ename": type(e).__name__, "evalue": str(e), "traceback": [str(e)]}]

    if line.startswith("%matplotlib"):
        return [{"type": "stream", "name": "stdout", "text": "Matplotlib backend: Agg (inline)\n"}]

    return None


def execute_code(code, exec_count):
    send_status("busy")
    outputs = []
    success = True
    code = code.replace("\r\n", "\n").replace("\r", "\n")

    # Check for magic lines
    lines = code.split("\n")
    for line in lines:
        s = line.strip()
        if s and (s.startswith("!") or s.startswith("%pip") or s.startswith("%conda") or s.startswith("%matplotlib")):
            result = _handle_magic(s)
            if result:
                for out in result:
                    send(out)
                send({"type": "execute_reply", "exec_count": exec_count, "success": True})
                send_status("idle")
                send_boundary()
                return

    old_stdout, old_stderr = sys.stdout, sys.stderr
    captured_out = io.StringIO()
    captured_err = io.StringIO()
    result = None

    try:
        sys.stdout = captured_out
        sys.stderr = captured_err
        try:
            compiled = compile(code, "<cell>", "eval")
            result = eval(compiled, _user_ns)
        except SyntaxError:
            exec(compile(code, "<cell>", "exec"), _user_ns)
    except Exception as e:
        success = False
        tb = e.__traceback__
        while tb is not None and "kernel_harness" in (tb.tb_frame.f_code.co_filename or ""):
            tb = tb.tb_next
        if tb is None:
            tb = e.__traceback__
        clean_lines = traceback.format_exception(type(e), e, tb)
        outputs.append({"type": "error", "ename": type(e).__name__, "evalue": str(e), "traceback": clean_lines})
    finally:
        sys.stdout = old_stdout
        sys.stderr = old_stderr

    stdout_text = captured_out.getvalue()
    if stdout_text:
        outputs.append({"type": "stream", "name": "stdout", "text": stdout_text})

    stderr_text = captured_err.getvalue()
    if stderr_text:
        outputs.append({"type": "stream", "name": "stderr", "text": stderr_text})

    try:
        import matplotlib.pyplot as plt
        figs = [plt.figure(i) for i in plt.get_fignums()]
        for fig in figs:
            display = _capture_display_data(fig)
            if display:
                outputs.append({"type": "display_data", "data": display})
        plt.close("all")
    except ImportError:
        pass

    if result is not None and success:
        display = _capture_display_data(result)
        if display:
            outputs.append({"type": "display_data", "data": display})
        else:
            outputs.append({"type": "execute_result", "data": {"text/plain": repr(result)}, "exec_count": exec_count})

    for out in outputs:
        send(out)

    send({"type": "execute_reply", "exec_count": exec_count, "success": success})
    send_status("idle")
    send_boundary()


def main():
    send_status("idle")
    send_boundary()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue

        msg_type = msg.get("type", "")
        if msg_type == "quit":
            break
        elif msg_type == "execute":
            code = msg.get("code", "")
            exec_count = msg.get("exec_count", 0)
            if code.strip():
                execute_code(code, exec_count)
            else:
                send({"type": "execute_reply", "exec_count": exec_count, "success": True})
                send_boundary()


if __name__ == "__main__":
    main()
