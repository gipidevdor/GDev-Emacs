#!/usr/bin/env python3
"""Ricostruisce gli indici delle fonti locali; nessun download o valutazione."""
# Copyright (C) 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: GPL-3.0-or-later
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "docs/assicurazione/standard"
TARGET = BASE / "indici-fonti.json"


def source(path):
    return {"path": path, "sha256": hashlib.sha256((BASE / path).read_bytes()).hexdigest()}


def nist():
    # Dipendenza del solo rigeneratore, non del runtime Emacs.
    from pypdf import PdfReader
    path = "fonti/nist-ir-8397/NIST.IR.8397.pdf"
    pages = [page.extract_text() or "" for page in PdfReader(BASE / path).pages]
    toc = re.findall(r"(?m)^(\d+(?:\.\d+)*)\s+(.+?)\s+(\d+)\s*$", pages[5])
    if len(toc) != 35:
        raise ValueError(f"Sommario NIST IR 8397 inatteso: {len(toc)} sezioni; riesaminare la fonte")
    nodes = []
    for number, title, printed in toc:
        parent = number.rsplit(".", 1)[0] if "." in number else None
        nodes.append({"id": number, "parent": parent, "title": title,
                      "kind": "recommendation" if number.startswith("2.") else "section",
                      "normative": number == "2" or number.startswith("2."),
                      "locator": f"PDF page {int(printed) + 7}; section {number}"})
    return {"id": "nist-ir-8397", "edition": "2021", "sources": [source(path)],
            "index_scope": "Tutte le sezioni numerate del sommario; PDF pagina 6",
            "index_complete": True, "requirements_complete": False,
            "missing": ["Scomposizione e revisione degli obblighi atomici nelle raccomandazioni della sezione 2; l'indice non sostituisce questa analisi."],
            "nodes": nodes}


def slsa():
    paths = ["fonti/slsa/build-track-basics.md", "fonti/slsa/source-requirements.md"]
    nodes = []
    for path in paths:
        stack = []
        prefix = Path(path).stem
        fenced = False
        for line_number, line in enumerate((BASE / path).read_text().splitlines(), 1):
            if line.startswith(("```", "~~~")):
                fenced = not fenced
            if fenced:
                continue
            heading = re.match(r"^(#{1,6})\s+(.+)", line)
            if heading:
                level, title = len(heading[1]), heading[2]
                while stack and stack[-1][0] >= level:
                    stack.pop()
                key = f"GDEV-{prefix}-L{line_number}"
                nodes.append({"id": key, "parent": stack[-1][1] if stack else None,
                              "title": title, "kind": "section", "official_id": False,
                              "locator": f"{path}:{line_number}"})
                stack.append((level, key))
            elif re.search(r"\b(must|shall|should|required)\b", line, re.I):
                nodes.append({"id": f"GDEV-{prefix}-L{line_number}",
                              "parent": stack[-1][1] if stack else None,
                              "title": "Obbligo candidato da revisionare", "kind": "obligation-candidate",
                              "official_id": False, "locator": f"{path}:{line_number}"})
    return {"id": "slsa", "edition": "1.2", "sources": [source(p) for p in paths],
            "index_scope": "Intestazioni e candidati delle due fonti Build e Source acquisite",
            "index_complete": True, "requirements_complete": False,
            "missing": ["Integrare gli altri documenti della specifica 1.2 e revisionare gli obblighi candidati; nessun livello è attribuito al progetto."],
            "nodes": nodes}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    data = {"schema_version": 1, "generator": "gdev-taxonomy-import-1",
            "notice": "Metadati e localizzatori originali GDev; contenuti normativi nelle fonti indicate.",
            "taxonomies": [nist(), slsa()]}
    rendered = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    if args.check:
        if not TARGET.is_file() or TARGET.read_text() != rendered:
            raise SystemExit("Indice da rigenerare: bin/gdev-taxonomy-import.py")
        print("Indici coerenti con le fonti locali")
    else:
        TARGET.write_text(rendered)
        print(f"Indice generato: {TARGET.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
