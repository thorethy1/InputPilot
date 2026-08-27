Import("env")

import os
import subprocess

project_dir = env.subst("$PROJECT_DIR")
repository = os.path.abspath(os.path.join(project_dir, ".."))
commit = os.environ.get("GITHUB_SHA", "")[:7]
if not commit:
    try:
        commit = subprocess.check_output(
            ["git", "rev-parse", "--short=7", "HEAD"], cwd=repository, text=True
        ).strip()
    except Exception:
        commit = "unknown"
env.Append(CPPDEFINES=[("FW_GIT_COMMIT", env.StringifyMacro(commit))])
