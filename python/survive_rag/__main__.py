"""Allow ``python -m survive_rag``."""

import sys

from .cli import main

sys.exit(main())
