from jinja2 import Template

template = "{{ range(1, (ctx.num_facilities | int * [1, (ctx.patients_needing_assessments_count | default(1000) | int / (ctx.num_facilities | int * ctx.page_size | int)) | round(0, 'ceil') | int] | max) + 1) | list }}"
ctx = {
    "num_facilities": 10,
    "page_size": 10,
    "patients_needing_assessments_count": 228
}

print(Template(template).render(ctx=ctx))
