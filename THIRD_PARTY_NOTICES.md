# Third-party notices

SteeringControl (OpenSteer) is MIT-licensed; see [LICENSE](LICENSE). It includes one
third-party binary and one third-party algorithm, listed here with their licenses.

## ViGEmClient.dll

The native user-mode client for the ViGEmBus driver, committed unmodified so the
Windows daemon builds with no download.

| Field | Value |
|---|---|
| File | `third_party/vigem/ViGEmClient.dll` |
| Upstream | ViGEmClient by Nefarius Software Solutions e.U., https://github.com/nefarius/ViGEmClient |
| Obtained from | The `costura64.vigemclient.dll` resource of the official `Nefarius.ViGEm.Client` 1.21.256 NuGet package |
| Version | FileVersion 1.21.233.0, x64 (PE32+), 141,312 bytes, not Authenticode-signed |
| SHA-256 | `00303f99e1968d523fbd08a7c691d60d145b7335059ec593947841d124c10875` |

The server build checks this hash (MSBuild target `VerifyViGEmClientHash` in
`server-windows/OpenSteer.Server/OpenSteer.Server.csproj`) and stops if the file
differs. Change both together, and only when upgrading the DLL.

The ViGEmBus kernel driver itself is not included. It is installed separately.

License, copied from the upstream repository:

```
MIT License

Copyright (c) 2018 Benjamin Höglinger-Stelzer

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## XXH32

The frame checksum is XXH32, the 32-bit member of the xxHash family designed by
Yann Collet. The four implementations in this repository (C#
`server-windows/OpenSteer.Core/Xxh32.cs`, Swift
`client-ios/Sources/OpenSteerCore/XXHash32.swift`, C++
`bridge-esp32/src/checksum.cpp`, Python `tools/osproto.py`) are written from the
published algorithm and checked against its reference test vectors. Credit and the
reference implementation's license:

```
xxHash Library
Copyright (c) 2012-2021 Yann Collet
All rights reserved.

BSD 2-Clause License (https://www.opensource.org/licenses/bsd-license.php)

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice, this
  list of conditions and the following disclaimer in the documentation and/or
  other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```
