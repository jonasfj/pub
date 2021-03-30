// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:test/test.dart';

import '../../descriptor.dart' as d;
import '../../test_pub.dart';

void main() {
  test('gets more than 16 packages from a pub server', () async {
    await servePackages((builder) {
      builder.serve('foo', '1.2.3');
      for (var i = 0; i < 20; i++) {
        builder.serve('pkg$i', '1.$i.0');
      }
    });

    await d.appDir({
      'foo': '1.2.3',
      for (var i = 0; i < 20; i++) 'pkg$i': '^1.$i.0',
    }).create();

    await pubGet();

    await d.cacheDir({
      'foo': '1.2.3',
      for (var i = 0; i < 20; i++) 'pkg$i': '1.$i.0',
    }).validate();

    await d.appPackagesFile({
      'foo': '1.2.3',
      for (var i = 0; i < 20; i++) 'pkg$i': '1.$i.0',
    }).validate();
  });
}