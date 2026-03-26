project = 'banzai-plugins'
author = 'Brendan Bank'
copyright = 'Brendan Bank. Licensed under the BSD 2-Clause License'
extensions = ['sphinx_tabs.tabs', 'sphinxcontrib.mermaid']
html_theme = 'sphinx_rtd_theme'
html_theme_options = {
    'collapse_navigation': False,
    'navigation_depth': 3,
}
html_static_path = ['_static']
html_css_files = ['custom.css']
html_copy_source = False
mermaid_height = 'auto'
