import os
import sys

# access.py lives in app/ and is import-side-effect free, so the access-control logic can be
# unit-tested without the rest of the FastAPI app or any Azure clients.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))
