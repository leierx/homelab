"""Offline approximation of the fleet ApplicationSets (see docs/fleet-gitops.md).

Mirrors Argo CD closely enough to catch template, data and YAML-shape errors before pushing:
git files generators (with exclude and values), matrix param merging (first child wins),
generator interpolation, elementsYaml, template + templatePatch, the finalizer default,
and a minimal kustomize (resources, nameSuffix, inline JSON6902 patches).

It is NOT Argo CD. Template functions are re-implemented in main.go with sprig's semantics.
Use it as a fast check; Argo CD itself is the source of truth.

Usage: python3 -I simulate.py <repo-root> <render-binary> [--quiet]
"""
import copy
import fnmatch
import glob
import json
import os
import subprocess
import sys
import tempfile

import yaml

REPO, RENDER = sys.argv[1], sys.argv[2]
QUIET = "--quiet" in sys.argv


class RenderError(Exception):
    pass


def render(tmpl, params):
    with tempfile.NamedTemporaryFile("w", delete=False, suffix=".tmpl") as t, \
            tempfile.NamedTemporaryFile("w", delete=False, suffix=".json") as p:
        t.write(tmpl)
        json.dump(params, p)
    try:
        r = subprocess.run([RENDER, t.name, p.name], capture_output=True, text=True)
    finally:
        os.unlink(t.name)
        os.unlink(p.name)
    if r.returncode != 0:
        raise RenderError(r.stderr.strip())
    return r.stdout


def render_strings(obj, params):
    """Argo renders every string field of the template on its own."""
    if isinstance(obj, dict):
        return {k: render_strings(v, params) for k, v in obj.items()}
    if isinstance(obj, list):
        return [render_strings(v, params) for v in obj]
    if isinstance(obj, str) and "{{" in obj:
        return render(obj, params)
    return obj


def deep_merge(dst, src):
    """mergo.Merge(dst, src, WithOverride) for maps: src wins, maps merge recursively."""
    out = copy.deepcopy(dst)
    for k, v in src.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = copy.deepcopy(v)
    return out


def matrix_merge(a, b):
    """Matrix: tmp <- b, then tmp <- a with override (first child wins)."""
    return deep_merge(deep_merge({}, b), a)


def path_params(dirpath, filename=None):
    p = {
        "path": dirpath,
        "basename": os.path.basename(dirpath),
        "basenameNormalized": os.path.basename(dirpath),
        "segments": dirpath.split("/"),
    }
    if filename:
        p["filename"] = filename
        p["filenameNormalized"] = filename
    return p


def git_files(pattern):
    """Default (non-doublestar) globbing is `git ls-files -- <pattern>`: * crosses /."""
    out = []
    for f in sorted(glob.glob(os.path.join(REPO, "**", "*"), recursive=True)):
        rel = os.path.relpath(f, REPO)
        if os.path.isfile(f) and fnmatch.fnmatchcase(rel, pattern):
            content = yaml.safe_load(open(f)) or {}
            if isinstance(content, list):
                items = content
            else:
                items = [content]
            for item in items:
                params = dict(item)
                params["path"] = path_params(os.path.dirname(rel), os.path.basename(rel))
                out.append(params)
    return out


def git_dirs(pattern):
    """Directory generator matches with path.Match: * does not cross /."""
    import re
    rx = "^" + "/".join(re.escape(seg).replace(r"\*", "[^/]*") for seg in pattern.split("/")) + "$"
    out = []
    for root, dirs, _ in os.walk(REPO):
        for d in dirs:
            rel = os.path.relpath(os.path.join(root, d), REPO)
            if re.match(rx, rel):
                out.append({"path": path_params(rel)})
    return sorted(out, key=lambda p: p["path"]["path"])


def interpolate(gen, params):
    return render_strings(gen, params) if params else gen


def run_generator(gen, parent=None):
    gen = interpolate(gen, parent or {})
    if "list" in gen:
        res = [dict(e) for e in gen["list"].get("elements", [])]
        if gen["list"].get("elementsYaml"):
            res += yaml.safe_load(gen["list"]["elementsYaml"]) or []
        return res
    if "git" in gen:
        g = gen["git"]
        if "files" in g:
            inc = [f["path"] for f in g["files"] if not f.get("exclude")]
            exc = [f["path"] for f in g["files"] if f.get("exclude")]
            res = []
            for pat in inc:
                for prm in git_files(pat):
                    rel = prm["path"]["path"] + "/" + prm["path"]["filename"]
                    if any(fnmatch.fnmatchcase(rel, e) for e in exc):
                        continue
                    if g.get("values"):
                        prm["values"] = {k: render(v, prm) if "{{" in v else v for k, v in g["values"].items()}
                    res.append(prm)
            return res
        res = []
        for d in g["directories"]:
            res += git_dirs(d["path"])
        return res
    if "matrix" in gen:
        c0, c1 = gen["matrix"]["generators"]
        out = []
        for a in run_generator(c0, parent):
            for b in run_generator(c1, a):
                out.append(matrix_merge(a, b))
        return out
    raise ValueError(f"unsupported generator {list(gen)}")


def strategic_merge(base, patch):
    out = copy.deepcopy(base)
    for k, v in patch.items():
        if k == "finalizers" and isinstance(out.get(k), list):
            out[k] = out[k] + [f for f in v if f not in out[k]]
        elif isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = strategic_merge(out[k], v)
        else:
            out[k] = v
    return out


def generate(appset):
    spec = appset["spec"]
    apps = []
    for gen in spec["generators"]:
        for params in run_generator(gen):
            app = {"apiVersion": "argoproj.io/v1alpha1", "kind": "Application",
                   **render_strings(spec["template"], params)}
            preserve = (spec.get("syncPolicy") or {}).get("preserveResourcesOnDeletion", False)
            if not preserve and not app["metadata"].get("finalizers"):
                app["metadata"]["finalizers"] = ["resources-finalizer.argocd.argoproj.io"]
            if spec.get("templatePatch"):
                patch_text = render(spec["templatePatch"], params)
                app = strategic_merge(app, yaml.safe_load(patch_text))
            apps.append(app)
    names = [a["metadata"]["name"] for a in apps]
    dupes = {n for n in names if names.count(n) > 1}
    if dupes:
        raise RenderError(f"duplicate Application names: {sorted(dupes)}")
    return apps


def json_patch(doc, ops):
    doc = copy.deepcopy(doc)
    for op in ops:
        assert op["op"] in ("replace", "add"), op
        parts = op["path"].lstrip("/").split("/")
        cur = doc
        for p in parts[:-1]:
            cur = cur[int(p)] if isinstance(cur, list) else cur[p]
        last = parts[-1]
        if isinstance(cur, list):
            assert int(last) < len(cur), f"path {op['path']} does not exist"
            cur[int(last)] = op["value"]
        else:
            if op["op"] == "replace":
                assert last in cur, f"path {op['path']} does not exist"
            cur[last] = op["value"]
    return doc


def kustomize_build(rel, name_prefix, extra_patches):
    """Tiny kustomize: resources (files or dirs), nameSuffix, inline JSON6902 patches by kind."""
    kdir = os.path.join(REPO, rel)
    k = yaml.safe_load(open(os.path.join(kdir, "kustomization.yaml")))
    docs = []
    for r in k.get("resources", []):
        rp = os.path.normpath(os.path.join(rel, r))
        if os.path.isdir(os.path.join(REPO, rp)):
            docs += kustomize_build(rp, "", [])
        else:
            docs += list(yaml.safe_load_all(open(os.path.join(REPO, rp))))
    for pt in k.get("patches", []) + extra_patches:
        ops = yaml.safe_load(pt["patch"])
        docs = [json_patch(d, ops) if d["kind"] == pt["target"]["kind"] else d for d in docs]
    for d in docs:
        d["metadata"]["name"] = name_prefix + d["metadata"]["name"] + k.get("nameSuffix", "")
    return docs


def main():
    fleet = yaml.safe_load(open(os.path.join(REPO, "gitops/bootstrap/fleet.yaml")))
    cluster_apps = generate(fleet)
    results = {}
    for capp in cluster_apps:
        src = capp["spec"]["sources"][0]
        appsets = kustomize_build(src["path"], src["kustomize"]["namePrefix"], src["kustomize"]["patches"])
        cluster = capp["metadata"]["name"].removeprefix("cluster-")
        results[cluster] = (capp, [(a, generate(a)) for a in appsets])

    for cluster, (capp, sets) in results.items():
        reg = capp["spec"]["sources"][1]
        fin = "cascade" if capp["metadata"].get("finalizers") else "none"
        print(f"\n=== {capp['metadata']['name']} (finalizer: {fin}; registration: {reg['path']}/{reg['directory']['include']})")
        for appset, apps in sets:
            strategy = appset["spec"].get("strategy", {}).get("type", "AllAtOnce")
            print(f"  -- ApplicationSet {appset['metadata']['name']} [{strategy}]")
            key = lambda a: (int(a["metadata"]["labels"].get("fleet/wave", "0")), a["metadata"]["name"])
            for a in sorted(apps, key=key):
                lab = a["metadata"]["labels"]
                s0 = a["spec"]["sources"][0]
                kind = "helm" if "helm" in s0 else "auto"
                fz = "delete" if a["metadata"].get("finalizers") else "keep"
                auto = "rolling" if strategy == "RollingSync" else "auto"
                wave = lab.get("fleet/wave", "-")
                print(f"     w{wave:1} {a['metadata']['name']:30} {lab['fleet/kind']:5} ns={a['spec']['destination']['namespace']:12} "
                      f"{kind:4} onRemoval={fz:6} {auto:7} path={s0['path']}")
                if not QUIET:
                    if "helm" in s0:
                        print(f"          release={s0['helm']['releaseName']} values={s0['helm'].get('valueFiles', [])}")
                    for s in a["spec"]["sources"][1:]:
                        if "ref" not in s:
                            print(f"          layers include={s['directory']['include']}")
                    so = a["spec"]["syncPolicy"]["syncOptions"]
                    if len(so) > 2:
                        print(f"          syncOptions={so}")
            if strategy == "RollingSync":
                steps = [s["matchExpressions"][0]["values"][0] for s in appset["spec"]["strategy"]["rollingSync"]["steps"]]
                bad = [a["metadata"]["name"] for a in apps if a["metadata"]["labels"].get("fleet/wave") not in steps]
                assert not bad, f"apps outside every RollingSync step: {bad}"
        names = [a["metadata"]["name"] for _, apps in sets for a in apps]
        dup = {n for n in names if names.count(n) > 1}
        assert not dup, f"same Application in both ApplicationSets: {dup}"

    out = os.environ.get("SIM_OUT")
    if out:
        with open(out, "w") as f:
            docs = []
            for cluster, (capp, sets) in results.items():
                docs.append(capp)
                for appset, apps in sets:
                    docs += [appset] + apps
            yaml.safe_dump_all(docs, f, sort_keys=False)


if __name__ == "__main__":
    try:
        main()
    except RenderError as e:
        print("RENDER ERROR:", e)
        sys.exit(1)
