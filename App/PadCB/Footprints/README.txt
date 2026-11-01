Bundled KiCad footprint libraries land here at CI build time.

The build workflow downloads the pinned kicad-footprints release
(GitLab, 10.0.1), copies ONLY the *.pretty library folders (the
.kicad_mod files — no 3D models) plus the upstream license into this
folder, and runs tools/FootprintCensus with the app's real Swift
parser over the whole corpus: the census must be clean before the
app builds, and it emits FootprintIndex.json (group/name/description/
tags/pad+graphic counts per footprint) which FootprintStore loads at
launch. Individual bundled footprints are parsed on demand from the
.kicad_mod files stored here verbatim.
