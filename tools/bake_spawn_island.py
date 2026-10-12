"""Bake assets/spawn_island_ultra.obj into the drop-in SpawnOnIsland script.

The .obj comes without its .mtl/texture, so each triangle is coloured from
what it is (object, atlas row it uses, facing, height). The mesh is
simplified to a part budget Roblox handles well (two wedges per triangle).

    pip install pillow fast-simplification numpy
    python3 tools/bake_spawn_island.py
"""

import sys
from pathlib import Path

import fast_simplification
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "assets" / "spawn_island_ultra.obj"
TEMPLATE = ROOT / "tools" / "standalone" / "spawn_island_template.luau"
OUT = ROOT / "tools" / "SpawnOnIsland.server.luau"

# Triangles kept per object (the source has ~74k).
BUDGET = {
    "SpawnIsland_terrain": 2600,
    "SpawnIsland_cliff": 1400,
    "SpawnIsland_pit": 900,
    "SpawnIsland_trees": 1800,
    "SpawnIsland_nature_1": 1300,
    "SpawnIsland_nature_2": 500,
    "SpawnIsland_props": 900,
}
PIT_CENTER = np.array([0.2, -0.3])  # x, z


def load(path):
    verts, uvs, objects, current = [], [], {}, None
    with open(path) as f:
        for line in f:
            if line.startswith("v "):
                verts.append([float(x) for x in line.split()[1:4]])
            elif line.startswith("vt "):
                uvs.append([float(x) for x in line.split()[1:3]])
            elif line.startswith("o "):
                current = line.split()[1]
                objects[current] = []
            elif line.startswith("f "):
                corners = [tuple(int(x) - 1 for x in c.split("/")[:2]) for c in line.split()[1:]]
                for i in range(1, len(corners) - 1):
                    objects[current].append((corners[0], corners[i], corners[i + 1]))
    return np.array(verts), np.array(uvs), objects


def lerp(a, b, t):
    t = min(1.0, max(0.0, t))
    return tuple(int(round(x + (y - x) * t)) for x, y in zip(a, b))


def face_class(obj, centre, normal, uv, comp):
    """Colour class of one source face. comp describes its connected piece."""
    x, y, z = centre
    u, v = uv
    if obj == "SpawnIsland_terrain":
        if 0.6 < v < 0.85:
            return "path"
        if normal[1] < 0.5 or u < 0.3:
            return "dirt"
        return "grass"
    if obj == "SpawnIsland_cliff":
        return "cliff_top" if y > 10.6 else "cliff"
    if obj == "SpawnIsland_pit":
        if y > 12.3:
            return "crystal"
        if np.hypot(x - PIT_CENTER[0], z - PIT_CENTER[1]) < 2.8 and y < 11.7:
            return "shaft"
        return "rim"
    if obj == "SpawnIsland_trees":
        if comp["thin"] and comp["low"]:
            return "trunk"
        return "pine" if comp["u"] > 0.6 else "leaves"
    if obj == "SpawnIsland_nature_1":
        if comp["v"] > 0.85:
            return "tuft"
        if comp["u"] > 0.75:
            return "rock"
        return "bush"
    if obj == "SpawnIsland_nature_2":
        return "tuft"
    if obj == "SpawnIsland_props":
        if comp["u"] > 0.9:
            return "lamp"
        if comp["v"] < 0.1:
            return "metal"
        return "wood"
    return "other"


def colour(cls, centre, uv, seed):
    y = centre[1]
    u = uv[0]
    jitter = ((seed * 2654435761) % 1000) / 1000  # per-piece variety
    if cls == "path":
        return lerp((214, 200, 168), (186, 170, 140), jitter)
    if cls == "dirt":
        return (139, 94, 60)
    if cls == "grass":
        return lerp((86, 182, 66), (122, 210, 84), (u - 0.5) / 0.2)
    if cls == "cliff_top":
        return (128, 88, 56)
    if cls == "cliff":
        return lerp((92, 78, 74), (124, 88, 60), y / 10.6)
    if cls == "crystal":
        return (196, 150, 255)
    if cls == "shaft":
        return lerp((150, 80, 255), (50, 26, 92), (y - 6) / 5)
    if cls == "rim":
        return (150, 140, 172)
    if cls == "trunk":
        return (118, 80, 50)
    if cls == "pine":
        return lerp((40, 124, 58), (62, 150, 68), jitter)
    if cls == "leaves":
        return lerp((76, 170, 58), (124, 206, 80), jitter)
    if cls == "tuft":
        return lerp((98, 190, 72), (146, 224, 98), jitter)
    if cls == "rock":
        return lerp((150, 150, 162), (186, 186, 196), jitter)
    if cls == "bush":
        return lerp((56, 146, 54), (90, 182, 68), jitter)
    if cls == "lamp":
        return (255, 222, 130)
    if cls == "metal":
        return (90, 90, 100)
    if cls == "wood":
        return lerp((140, 94, 58), (176, 122, 76), jitter)
    return (200, 200, 200)


def components(faces, nverts):
    parent = list(range(nverts))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    for a, b, c in faces:
        ra, rb, rc = find(a), find(b), find(c)
        parent[rb] = ra
        parent[find(rc)] = ra
    return np.array([find(f[0]) for f in faces])


V, UV, OBJ = load(SRC)
palette, meshes = {}, []


def add_colour(rgb):
    col = "%02x%02x%02x" % rgb
    if col not in palette:
        palette[col] = len(palette) + 1
    return palette[col]


for name, tris in OBJ.items():
    idx = np.array([[c[0] for c in t] for t in tris])
    uvi = np.array([[c[1] for c in t] for t in tris])
    # Weld identical positions so pieces connect and simplification works.
    keys = np.round(V[idx.ravel()], 4)
    uniq, inverse = np.unique(keys, axis=0, return_inverse=True)
    faces = inverse.reshape(-1, 3)
    centres = V[idx].mean(1)
    face_uv = UV[uvi].mean(1)
    p = uniq[faces]
    normals = np.cross(p[:, 1] - p[:, 0], p[:, 2] - p[:, 0])
    normals /= np.maximum(np.linalg.norm(normals, axis=1, keepdims=True), 1e-12)
    comp = components(faces, len(uniq))
    info = {}
    for cid in np.unique(comp):
        sel = comp == cid
        pts = uniq[np.unique(faces[sel])]
        ext = pts.max(0) - pts.min(0)
        info[cid] = {
            "thin": max(ext[0], ext[2]) < 1.0 and ext[1] > max(ext[0], ext[2]),
            "low": pts[:, 1].min() < 12.8,
            "u": float(np.median(face_uv[sel, 0])),
            "v": float(np.median(face_uv[sel, 1])),
        }
    classes = np.array(
        [face_class(name, centres[i], normals[i], face_uv[i], info[comp[i]]) for i in range(len(faces))]
    )
    budget = BUDGET.get(name, 800)
    verts, out, vmap = [], [], {}
    for cls in np.unique(classes):
        sel = np.nonzero(classes == cls)[0]
        # Simplify each colour class on its own so colours keep their shapes.
        sub = faces[sel]
        used, local = np.unique(sub.ravel(), return_inverse=True)
        sub_pts, sub_faces = uniq[used], local.reshape(-1, 3)
        target = max(4, int(budget * len(sel) / len(faces)))
        if len(sub_faces) > target and len(sub_faces) > 40:
            sub_pts, sub_faces = fast_simplification.simplify(
                sub_pts.astype(np.float32), sub_faces.astype(np.int32), 1 - target / len(sub_faces)
            )
        # Colour each new face like the nearest source face of this class.
        src_c = centres[sel]
        grid = {}
        for j, c in enumerate(src_c):
            grid.setdefault(tuple((c // 0.6).astype(int)), []).append(j)

        def nearest(c):
            k = (c // 0.6).astype(int)
            best, best_d = 0, 1e9
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    for dz in (-1, 0, 1):
                        for j in grid.get((k[0] + dx, k[1] + dy, k[2] + dz), ()):
                            d = ((src_c[j] - c) ** 2).sum()
                            if d < best_d:
                                best, best_d = j, d
            return sel[best], best_d

        for f in sub_faces:
            q = sub_pts[f]
            if np.linalg.norm(np.cross(q[1] - q[0], q[2] - q[0])) < 1e-9:
                continue
            c = q.mean(0)
            i, dist2 = nearest(c)
            if dist2 > 0.35**2:
                continue  # bridges a gap in this class (simplification artefact)
            k = add_colour(colour(cls, c, face_uv[i], int(comp[i])))
            ids = []
            for vi in f:
                key = tuple(int(round(x * 100)) for x in sub_pts[vi])
                if key not in vmap:
                    vmap[key] = len(verts) + 1
                    verts.append(key)
                ids.append(vmap[key])
            if len(set(ids)) == 3:
                out.append((*ids, k))
    meshes.append((name, verts, out))
    print(f"{name}: {len(tris)} -> {len(out)} triangles", file=sys.stderr)

lines = ["{", "\tpalette = {", *['\t\t"%s",' % c for c in palette], "\t},", "\tmeshes = {"]
for name, verts, tris in meshes:
    lines += [
        "\t\t{",
        '\t\t\tname = "%s",' % name,
        '\t\t\tverts = "%s",' % " ".join("%d %d %d" % v for v in verts),
        '\t\t\ttris = "%s",' % " ".join("%d %d %d %d" % t for t in tris),
        "\t\t},",
    ]
lines += ["\t},", "}"]
OUT.write_text(TEMPLATE.read_text().replace("--[[DATA]]", "\n".join(lines), 1))
total = sum(len(t) for _, _, t in meshes)
print(f"{OUT.relative_to(ROOT)}: {total} triangles, {len(palette)} colours", file=sys.stderr)
