import re
with open("repos/noetl/noetl/tools/postgres/command.py", "r") as f:
    text = f.read()

old_func = re.search(r'def render_and_split_commands.*?return statements\n', text, re.DOTALL)
if old_func:
    new_func = """def render_and_split_commands(commands: str, jinja_env: Environment, context: Dict, task_with: Dict) -> List[str]:
    \"\"\"
    Render SQL commands with Jinja2 and split into individual statements.
    
    This function:
    1. Renders the commands string with Jinja2 templates
    2. Splits commands on semicolons while respecting:
       - Single quotes (')
       - Double quotes (")
       - Dollar-quoted strings ($tag$...$tag$)
       - Single line and multi-line comments
    
    Args:
        commands: The SQL commands string (may contain Jinja2 templates)
        jinja_env: The Jinja2 environment for template rendering
        context: The context for rendering templates
        task_with: The rendered 'with' parameters dictionary
        
    Returns:
        List of individual SQL statement strings
    \"\"\"
    logger.debug(f"POSTGRES: Rendering commands with context keys: {list(context.keys()) if isinstance(context, dict) else type(context)}")
    if isinstance(context, dict) and 'result' in context:
        result_val = context['result']
        logger.debug(f"POSTGRES: Found 'result' in context - type: {type(result_val)}, keys: {list(result_val.keys()) if isinstance(result_val, dict) else 'not dict'}")
    else:
        logger.debug("POSTGRES: No 'result' found in context")
    
    # Render commands with combined context
    commands_rendered = render_template(jinja_env, commands, {**context, **task_with})
    
    # Fast regex-based SQL statement splitting
    import re
    pattern = re.compile(
        r"('(?:''|\\\\.|[^'])*')|"            # Single quote strings
        r'("(?:""|\\\\.|[^"])*")|'            # Double quote strings
        r'(\\$[a-zA-Z0-9_]*\\$.*?\\3)|'        # Dollar quoted strings
        r'(--[^\\n]*)|'                      # Single-line comments
        r'(/\\*.*?\\*/)|'                     # Multi-line comments
        r'(;)|'                             # Semicolons
        r'([^;\\\'"$-/]+|.)',                 # Anything else
        re.DOTALL
    )
    
    statements = []
    current = []
    
    for match in pattern.finditer(commands_rendered):
        if match.group(6):  # Semicolon
            stmt = "".join(current).strip()
            if stmt:
                statements.append(stmt)
            current.clear()
        elif match.group(4) or match.group(5):
            pass  # Ignore comments
        else:
            current.append(match.group(0))
            
    if current:
        stmt = "".join(current).strip()
        if stmt:
            statements.append(stmt)

    return statements
"""
    with open("repos/noetl/noetl/tools/postgres/command.py", "w") as f:
        f.write(text[:old_func.start()] + new_func + text[old_func.end():])
    print("Replaced.")
