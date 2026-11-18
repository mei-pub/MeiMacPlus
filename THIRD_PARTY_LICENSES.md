# Third-Party Licenses

MeiMacPlus embeds and derives from the following open-source components.

## Hammerspoon (MIT)

Vendored runtime: `LuaSkin.framework` (incl. Lua 5.4.7), 86 `hs.*` native
dylibs, pure-Lua extensions and `setup.lua`, `docs.json` — extracted from the
official [Hammerspoon 1.1.1](https://github.com/Hammerspoon/hammerspoon)
release by `scripts/fetch_hs_runtime.sh`. Also vendored as compiled source:
`MeiMacPlus/Source/Scripting/Vendor/HSuicore.h/.m`. Adapted in-tree
(derivative works): `MeiMacPlus/Source/Scripting/LuaRuntime.m` and
`HSMJStubs.m` (from upstream `MJLua.m` and app-layer symbols).

The upstream app binary, Sparkle, and modules whose dylibs link libraries we
do not vendor are **not** included (see README → Scripting for the excluded
`hs.*` modules).

```
The MIT License (MIT)

Copyright (c) 2014-2025 [Various Contributors](https://github.com/Hammerspoon/hammerspoon/graphs/contributors)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

## Lua 5.4.7 (MIT)

Distributed unmodified inside LuaSkin.framework.

```
Copyright (C) 1994-2024 Lua.org, PUC-Rio.

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## Behavioral inspiration (no code copied)

- [SlowQuitApps](https://github.com/dteoh/SlowQuitApps) (GPL-2.0) — hold-⌘Q interaction design.
- [Mos](https://github.com/Caldis/Mos) (CC BY-NC 4.0) — smooth scrolling behavior design.

## Upgrade procedure

Bump `HS_VERSION`/`HS_SHA256` in `scripts/fetch_hs_runtime.sh`, delete
`build/hs-vendor`, re-run the script, and refresh the version references
above. Verify the excluded-dylib and host-symbol lists still hold (the
`testAllVendoredModulesLoad` unit test is the regression gate).
