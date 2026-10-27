from collections import Counter

from convert import ecosystem, licence, refresh_weekday, sentinel_rows, spdx_to_cyclonedx


def _purls(spdx):
    return {x["referenceLocator"] for p in spdx["packages"] for x in p.get("externalRefs", [])
            if x["referenceType"] == "purl"}


def test_root_package_dropped(spdx):
    cdx = spdx_to_cyclonedx(spdx, "actions", "setup-python", "main")
    names = [c["name"] for c in cdx["components"]]
    assert "com.github.actions/setup-python" not in names
    assert len(names) == len(spdx["packages"]) - 1


def test_every_purl_survives(spdx):
    """Dependency-Track matches vulnerabilities on the purl: losing one is a silent false negative."""
    root = next(r["relatedSpdxElement"] for r in spdx["relationships"] if r["relationshipType"] == "DESCRIBES")
    expected = _purls({"packages": [p for p in spdx["packages"] if p["SPDXID"] != root]})
    cdx = spdx_to_cyclonedx(spdx, "actions", "setup-python", "main")
    assert {c["purl"] for c in cdx["components"]} == expected


def test_scoped_npm_and_actions_names_kept(spdx):
    cdx = spdx_to_cyclonedx(spdx, "actions", "setup-python", "main")
    by_name = {c["name"]: c for c in cdx["components"]}
    assert by_name["@azure/core-rest-pipeline"]["purl"].startswith("pkg:npm/%40azure/core-rest-pipeline@")
    assert by_name["actions/checkout"]["purl"].startswith("pkg:githubactions/actions/checkout@")


def test_licences(spdx):
    cdx = spdx_to_cyclonedx(spdx, "actions", "setup-python", "main")
    by_name = {c["name"]: c for c in cdx["components"]}
    assert by_name["packaging"]["licenses"] == [{"expression": "Apache-2.0 AND BSD-2-Clause"}]
    assert "licenses" not in by_name["kivy-deps-gstreamer"]  # no licenseConcluded in GitHub's SBOM


def test_licence_skips_noassertion_and_falls_back_to_declared():
    assert licence({"licenseConcluded": "NOASSERTION", "licenseDeclared": "MIT"}) == "MIT"
    assert licence({"licenseConcluded": "NONE"}) is None
    assert licence({}) is None


def test_package_without_purl_or_version():
    spdx = {"packages": [{"SPDXID": "SPDXRef-x", "name": "vendored-lib"}], "relationships": []}
    (c,) = spdx_to_cyclonedx(spdx, "o", "r", "main")["components"]
    assert c == {"type": "library", "bom-ref": "SPDXRef-x", "name": "vendored-lib"}


def test_metadata(spdx):
    cdx = spdx_to_cyclonedx(spdx, "actions", "setup-python", "main", timestamp="2026-10-27T02:00:00+00:00")
    assert cdx["bomFormat"] == "CycloneDX" and cdx["specVersion"] == "1.5"
    assert cdx["metadata"]["component"] == {"type": "application", "name": "actions/setup-python", "version": "main"}
    assert cdx["metadata"]["timestamp"] == "2026-10-27T02:00:00+00:00"


def test_ecosystem():
    assert ecosystem("pkg:npm/%40azure/core-rest-pipeline@1.0.0") == "npm"
    assert ecosystem("pkg:pypi/packaging@20.7") == "pypi"
    assert ecosystem("") == ""


def test_sentinel_rows(spdx):
    cdx = spdx_to_cyclonedx(spdx, "actions", "setup-python", "main")
    rows = sentinel_rows(cdx, "actions", "setup-python", "main", "2026-10-27T02:00:00+00:00")
    assert len(rows) == len(cdx["components"])
    assert {r["TimeGenerated"] for r in rows} == {"2026-10-27T02:00:00+00:00"}  # one snapshot, one timestamp
    pkg = next(r for r in rows if r["PackageName"] == "packaging")
    assert pkg == {"TimeGenerated": "2026-10-27T02:00:00+00:00", "Org": "actions", "Repo": "setup-python",
                   "Branch": "main", "PackageName": "packaging", "PackageVersion": "20.7",
                   "Purl": "pkg:pypi/packaging@20.7", "Ecosystem": "pypi", "License": "Apache-2.0 AND BSD-2-Clause"}
    assert next(r for r in rows if r["PackageName"] == "kivy-deps-gstreamer")["License"] == ""


def test_refresh_weekday_is_stable_and_spread():
    assert refresh_weekday("CPS", "Repo") == refresh_weekday("cps", "repo")
    days = Counter(refresh_weekday("cps", f"repo-{i}") for i in range(7000))
    assert set(days) == set(range(7))
    assert min(days.values()) > 800  # roughly 1/7 of repos each night
