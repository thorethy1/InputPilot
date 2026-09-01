Import("env")

import sys
from pathlib import Path


repository = Path(env.subst("$PROJECT_DIR")).resolve().parent
sys.path.insert(0, str(repository))
from versioning import firmware_bcd_literal, release_version  # noqa: E402


version_file = repository / "Version.xcconfig"
env.Append(
    CPPDEFINES=[
        ("FW_VERSION", env.StringifyMacro(release_version(version_file))),
        ("FW_VERSION_BCD", firmware_bcd_literal(version_file)),
    ]
)
