#!/usr/bin/env python3
"""Confronta le tassonomie runtime con CSV/XLSX/PDF originali locali."""
# Copyright (C) 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: GPL-3.0-or-later
import csv
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "docs/assicurazione/standard"
EMACS = os.environ.get("EMACS", shutil.which("emacs") or "emacs")
NS = {"s": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}


def taxonomy(identifier):
    with tempfile.TemporaryDirectory(prefix="gdev-taxonomy-") as temporary:
        env = dict(os.environ, GDEV_STATE_DIR=temporary + "/state", GDEV_USER_DIR=temporary + "/user")
        expression = '(progn (require \'gdev-taxonomy) (princ (decode-coding-string (json-serialize (gdev-taxonomy-data ' + json.dumps(identifier) + ')) \'utf-8-unix)))'
        result = subprocess.run([EMACS, "--batch", "-Q", "-l", str(ROOT / "early-init.el"),
                                 "-L", str(ROOT / "lisp"), "--eval", expression], env=env,
                                capture_output=True, text=True, timeout=30, check=True)
        return json.loads(result.stdout)["taxonomies"][0]


class Sources(unittest.TestCase):
    def test_asvs_every_requirement_and_parent_matches_original_csv(self):
        path = BASE / "fonti/owasp-asvs/OWASP_Application_Security_Verification_Standard_5.0.0_en.csv"
        with path.open(newline="", encoding="utf-8-sig") as stream:
            rows = list(csv.DictReader(stream))
        actual = taxonomy("owasp-asvs")
        requirements = {row["id"]: row for row in actual["nodes"] if row["kind"] == "requirement"}
        self.assertEqual(345, len(rows))
        self.assertEqual({row["req_id"] for row in rows}, set(requirements))
        for row in rows:
            self.assertEqual(row["section_id"], requirements[row["req_id"]]["parent"])
            self.assertEqual(row["req_description"], requirements[row["req_id"]]["text"])
        self.assertTrue(all(source["verified"] for source in actual["sources"]))

    def test_ssdf_tasks_match_original_workbook(self):
        path = BASE / "fonti/nist-sp-800-218/nist.sp.800-218.ssdf-table.xlsx"
        with zipfile.ZipFile(path) as archive:
            shared = ET.fromstring(archive.read("xl/sharedStrings.xml"))
            strings = ["".join(node.itertext()) for node in shared.findall("s:si", NS)]
            sheet = ET.fromstring(archive.read("xl/worksheets/sheet1.xml"))
            texts = []
            for cell in sheet.findall(".//s:c", NS):
                value = cell.find("s:v", NS)
                if value is not None and cell.attrib.get("t") == "s":
                    texts.append(strings[int(value.text)])
        tasks = {match[1]: text for text in texts if (match := re.match(r"^([A-Z]+\.\d+\.\d+):", text))}
        actual = taxonomy("nist-sp-800-218")
        requirements = {row["id"]: row for row in actual["nodes"] if row["kind"] == "requirement"}
        self.assertEqual(42, len(tasks))
        self.assertEqual(set(tasks), set(requirements))
        for identifier, text in tasks.items():
            self.assertEqual(text, requirements[identifier]["text"])
            self.assertEqual(identifier.rsplit(".", 1)[0], requirements[identifier]["parent"])
        self.assertEqual(19, sum(row["kind"] == "practice" for row in actual["nodes"]))

    def test_generated_indices_and_protected_gaps_remain_explicit(self):
        subprocess.run([shutil.which("python3") or "python3", str(ROOT / "bin/gdev-taxonomy-import.py"), "--check"], check=True)
        nist = taxonomy("nist-ir-8397")
        self.assertEqual(35, len(nist["nodes"]))
        self.assertEqual("TO_INTEGRATE", nist["requirements_status"])
        self.assertEqual("BIBLIOGRAPHIC", taxonomy("iso-iec-ieee-29148")["index_status"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
