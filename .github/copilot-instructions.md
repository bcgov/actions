# Image promotion (local)

`build → image-tracker → deploy` by digest. Spec: `image-tracker/README.md`. Do **not** copy `quickstart-openshift` `merge.yml` (still `get-pr` + `:<pr>` tags) as the image contract.

Merge/promote: walk (`max_depth` e.g. `100`). Miss = `exit 1`. No fork special case. No mutable PR tag as the image identity.
