"""SPDX 2.3 (GitHub dependency graph) -> CycloneDX 1.5, and the helpers the
Sentinel rows share. Pure functions only, so they can be tested without Azure
or GitHub."""
import datetime as dt
import uuid


def licence(pkg):
    """First real licence on an SPDX package, or None."""
    for field in ("licenseConcluded", "licenseDeclared"):
        value = pkg.get(field)
        if value and value not in ("NOASSERTION", "NONE"):
            return value
    return None


def ecosystem(purl):
    """'pkg:npm/%40azure/core@1.0' -> 'npm'."""
    return purl.split(":", 1)[1].split("/", 1)[0] if purl.startswith("pkg:") else ""


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


def sentinel_rows(cdx, org, repo, branch, timestamp):
    """One GitHubSbom_CL row per component. Every row in a snapshot shares one
    timestamp so SbomLatest can pick the latest snapshot per repo."""
    return [{"TimeGenerated": timestamp, "Org": org, "Repo": repo, "Branch": branch,
             "PackageName": c["name"], "PackageVersion": c.get("version", ""),
             "Purl": c.get("purl", ""), "Ecosystem": ecosystem(c.get("purl", "")),
             "License": (c.get("licenses") or [{}])[0].get("expression", "")}
            for c in cdx["components"]]


def refresh_weekday(org, repo):
    """Weekday (0=Mon) on which an unchanged repo is re-collected anyway.

    The design doc refreshes every repo on Sunday, but generate-report has its
    own rate-limit bucket (x-ratelimit-resource: dependency_sbom, 100/hour on a
    user token), so a single-night refresh of a large org would take many
    hours. Spreading the refresh by a stable hash keeps every repo no more than
    7 days stale while sending ~1/7 of the estate each night."""
    return uuid.uuid5(uuid.NAMESPACE_URL, f"{org}/{repo}".lower()).int % 7
