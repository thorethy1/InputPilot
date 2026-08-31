Import("env")

import sys
from pathlib import Path


repository = Path(env.subst("$PROJECT_DIR")).resolve().parent
sys.path.insert(0, str(repository))
from versioning import firmware_bcd_literal, project_version  # noqa: E402


version_file = repository / "Version.xcconfig"
env.Append(
    CPPDEFINES=[
        ("FW_VERSION", env.StringifyMacro(project_version(version_file))),
        ("FW_VERSION_BCD", firmware_bcd_literal(version_file)),
    ]
)
