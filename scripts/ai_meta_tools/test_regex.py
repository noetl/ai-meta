import re
pattern = re.compile(
        r"('(?:''|\\.|[^'])*')|"            # Single quote strings
        r'("(?:""|\\.|[^"])*")|'            # Double quote strings
        r'(\$[a-zA-Z0-9_]*\$.*?\3)|'        # Dollar quoted strings
        r'(--[^\n]*)|'                      # Single-line comments
        r'(/\*.*?\*/)|'                     # Multi-line comments
        r'(;)|'                             # Semicolons
        r'([^;\'"$-/]+|.)',                 # Anything else
        re.DOTALL
    )
