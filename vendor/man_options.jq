# The nested definition list under one `<term>` option of a pandoc man(7) AST, as
# TOML key/value lines: `<token> on|off` / `<token> N` term -> token, definition
# -> description. Errors rather than emitting a partial table: a changed man page
# must fail here, not silently yield mangled descriptions.
#
#   pandoc -f man -t json page.8 | jq -r --arg term "-A --pause" -f man_options.jq

# The plain text of an inline (or block) node, discarding formatting.
def txt:
  if type == "array" then map(txt) | join("")
  elif type == "object" then
    if .t == "Str" then .c
    elif .t == "Space" or .t == "SoftBreak" or .t == "LineBreak" then " "
    elif .t == "Code" then .c[1]
    elif (.c | type) == "array" then (.c | txt)
    else "" end
  else "" end;

# Every (term, definitions) pair below the current node.
def definitions: [ .. | objects | select(.t == "DefinitionList") | .c[] ];

[ definitions[] | select((.[0] | txt) == $term) ]
| if length != 1 then error("expected exactly one `\($term)` option") else .[0][1][0] end
| [ definitions[] | { token: ((.[0] | txt) | split(" ")[0]), desc: ((.[1] | txt) | sub("\\s+$"; "")) } ]
| if length == 0 then error("no entries under `\($term)`") else . end
| (map(select(.desc == "")) | if length > 0 then error("no description for `\(.[0].token)`") else empty end),
  (sort_by(.token)[] | "\(.token) = \(if (.desc | endswith(".")) then .desc else .desc + "." end | tojson)")
