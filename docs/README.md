# Documentation

This is the documentation for Chassis, written in reStructuredText, and
generated into the site at http://chassis.io/ by Read The Docs using Sphinx.

## Building documentation locally

You'll need a copy of [Python3.x](https://www.python.org/downloads/).

Then you'll need to grab a copy of Sphinx (the documentation generator) and
associated tools first:

```bash
$ sudo -H pip3 install Sphinx sphinx-autobuild sphinx_rtd_theme imagesize livereload==2.3.0
```

Then to build, run the `sphinx-build -b dirhtml . _build/dirhtml` within this documentation folder:

You should now be able to access `_build/dirhtml/index.html` in a browser and
browse the documentation.

The [doc2dash](https://doc2dash.readthedocs.io/en/stable/) parser is built for Python so we have used `py:data::` markup in `config.rst` so that an index of these values is generated for Dash.

### Building Offline Dash Documentation

We use [doc2dash](https://doc2dash.readthedocs.io/en/stable/) to generate offline documentation for [Dash](https://kapeli.com/dash).
If you wish to generate new documentation for Chassis then please to the following:

1. Run `pip3 install --user doc2dash`
1. Increase the [version number](https://github.com/Chassis/Chassis/blob/master/docs/conf.py#L57-L59) to match the release.
1. Run `sphinx-build -b html . _build/html` inside the `docs` folder.
1. Run `doc2dash -A _build/html/ -n Chassis -f -I index.html` to generate the new docset.
1. Follow the instructions for the [Dash User Contributed Docsets](https://github.com/Chassis/Dash-User-Contributions.git) repository and submit a pull request.

### Troubleshooting

If you see the error `sudo: pip: command not found` while installing the documentation generator, then you'll need to install pip with the following command:

```
$ sudo easy_install pip
```
