"""SPDX 2.3 (GitHub dependency graph) -> CycloneDX 1.5, and the rolling-refresh
schedule. Pure functions only, so they can be tested without Azure or GitHub."""
import datetime as dt
import uuid


def licence(pkg):
    """First real licence on an SPDX package, or None."""
    for field in ("licenseConcluded", "licenseDeclared"):
        value = pkg.get(field)
        if value and value not in ("NOASSERTION", "NONE"):
            return value
    return None


def purl_of(pkg):
    return next((x["referenceLocator"] for x in pkg.get("externalRefs", [])
                 if x.get("referenceType") == "purl"), None)


def spdx_to_cyclonedx(spdx, org, repo, branch, timestamp=None):
    """Minimal SPDX 2.3 -> CycloneDX 1.5: one library component per SPDX
    package except the repo itself. Dependency-Track matches vulnerabilities
    mainly on the purl, so that is the field this must never lose."""
    roots = {r["relatedSpdxElement"] for r in spdx.get("relationships", [])
             if r.get("relationshipType") == "DESCRIBES"}
    components = []
    for p in spdx.get("packages", []):
        if p["SPDXID"] in roots:
            continue
        c = {"type": "library", "bom-ref": p["SPDXID"], "name": p["name"]}
        if p.get("versionInfo"):
            c["version"] = p["versionInfo"]
        purl = purl_of(p)
        if purl:
            c["purl"] = purl
        lic = licence(p)
        if lic:
            c["licenses"] = [{"expression": lic}]
        components.append(c)
    return {"bomFormat": "CycloneDX", "specVersion": "1.5", "version": 1,
            "serialNumber": f"urn:uuid:{uuid.uuid4()}",
            "metadata": {"timestamp": timestamp or dt.datetime.now(dt.UTC).isoformat(),
                         "component": {"type": "application", "name": f"{org}/{repo}", "version": branch}},
            "components": components}


def refresh_weekday(org, repo):
    """Weekday (0=Mon) on which an unchanged repo is re-collected anyway.

    A weekly full refresh would be simplest, but generate-report has its
    own rate-limit bucket (x-ratelimit-resource: dependency_sbom, 100/hour per App
    installation), so a single-night refresh of a large org would take many
    hours. Spreading the refresh by a stable hash keeps every repo no more than
    7 days stale while sending ~1/7 of the org each night."""
    return uuid.uuid5(uuid.NAMESPACE_URL, f"{org}/{repo}".lower()).int % 7
