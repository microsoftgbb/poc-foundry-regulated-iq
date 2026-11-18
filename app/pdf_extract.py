import io
import json
import re
import resource
import sys

from pypdf import PdfReader
from pypdf.errors import PdfReadError


def extract(data: bytes) -> list[str]:
    if not data.startswith(b"%PDF-"):
        raise ValueError("A PDF file is required.")
    reader = PdfReader(io.BytesIO(data), strict=True)
    if reader.is_encrypted or not 1 <= len(reader.pages) <= 100:
        raise ValueError("Use an unencrypted PDF with 1 to 100 pages.")
    pages = []
    length = 0
    for page in reader.pages:
        text = page.extract_text() or ""
        length += len(text)
        if length > 200_000:
            raise ValueError("PDF extracted text exceeds 200,000 characters.")
        pages.append(text)
    combined = "\n".join(pages)
    if "SYNTHETIC" not in combined.upper():
        raise ValueError("Only PDFs explicitly marked SYNTHETIC are accepted.")
    feins = re.findall(r"\b\d{2}-\d{7}\b", combined)
    if not feins or any(not fein.startswith("00-") for fein in feins):
        raise ValueError("Synthetic PDFs must contain only FEINs beginning 00-.")
    if not any(page.strip() for page in pages):
        raise ValueError("No extractable text; scanned PDFs require OCR first.")
    return pages


if __name__ == "__main__":
    if sys.platform == "linux":
        resource.setrlimit(resource.RLIMIT_AS, (512 * 1024**2, 512 * 1024**2))
    resource.setrlimit(resource.RLIMIT_CPU, (10, 10))
    try:
        print(json.dumps({"pages": extract(sys.stdin.buffer.read(20 * 1024**2 + 1))}))
    except (ValueError, PdfReadError, OSError) as exc:
        print(json.dumps({"error": str(exc)}))
        sys.exit(2)
