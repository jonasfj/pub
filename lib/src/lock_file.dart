// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:collection';

import 'package:collection/collection.dart';
import 'package:package_config/packages_file.dart' as packages_file;
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:source_span/source_span.dart';
import 'package:yaml/yaml.dart';

import 'io.dart';
import 'package_name.dart';
import 'sdk.dart' show sdk;
import 'source_registry.dart';
import 'system_cache.dart';
import 'utils.dart';

/// A parsed and validated `pubspec.lock` file.
class LockFile {
  /// The packages this lockfile pins.
  final Map<String, PackageId> packages;

  /// The intersections of all SDK constraints for all locked packages, indexed
  /// by SDK identifier.
  Map<String, VersionConstraint> sdkConstraints;

  /// Dependency names that appeared in the root package's `dependencies`
  /// section.
  final Set<String> _mainDependencies;

  /// Dependency names that appeared in the root package's `dev_dependencies`
  /// section.
  final Set<String> _devDependencies;

  /// Dependency names that appeared in the root package's
  /// `dependency_overrides` section.
  final Set<String> _overriddenDependencies;

  /// Creates a new lockfile containing [ids].
  ///
  /// If passed, [mainDependencies], [devDependencies], and
  /// [overriddenDependencies] indicate which dependencies should be marked as
  /// being listed in the main package's `dependencies`, `dev_dependencies`, and
  /// `dependency_overrides` sections, respectively. These are consumed by the
  /// analysis server to provide better auto-completion.
  LockFile(Iterable<PackageId> ids,
      {Map<String, VersionConstraint> sdkConstraints,
      Set<String> mainDependencies,
      Set<String> devDependencies,
      Set<String> overriddenDependencies})
      : this._(
            Map.fromIterable(ids.where((id) => !id.isRoot),
                key: (id) => id.name),
            sdkConstraints ?? {"dart": VersionConstraint.any},
            mainDependencies ?? const UnmodifiableSetView.empty(),
            devDependencies ?? const UnmodifiableSetView.empty(),
            overriddenDependencies ?? const UnmodifiableSetView.empty());

  LockFile._(
      Map<String, PackageId> packages,
      this.sdkConstraints,
      this._mainDependencies,
      this._devDependencies,
      this._overriddenDependencies)
      : packages = UnmodifiableMapView(packages);

  LockFile.empty()
      : packages = const {},
        sdkConstraints = {"dart": VersionConstraint.any},
        _mainDependencies = const UnmodifiableSetView.empty(),
        _devDependencies = const UnmodifiableSetView.empty(),
        _overriddenDependencies = const UnmodifiableSetView.empty();

  /// Loads a lockfile from [filePath].
  factory LockFile.load(String filePath, SourceRegistry sources) {
    return LockFile._parse(filePath, readTextFile(filePath), sources);
  }

  /// Parses a lockfile whose text is [contents].
  factory LockFile.parse(String contents, SourceRegistry sources) {
    return LockFile._parse(null, contents, sources);
  }

  /// Parses the lockfile whose text is [contents].
  ///
  /// [filePath] is the system-native path to the lockfile on disc. It may be
  /// `null`.
  static LockFile _parse(
      String filePath, String contents, SourceRegistry sources) {
    if (contents.trim() == '') return LockFile.empty();

    Uri sourceUrl;
    if (filePath != null) sourceUrl = p.toUri(filePath);
    var parsed = loadYamlNode(contents, sourceUrl: sourceUrl);

    _validate(parsed is Map, 'The lockfile must be a YAML mapping.', parsed);
    var parsedMap = parsed as YamlMap;

    var sdkConstraints = <String, VersionConstraint>{};
    var sdkNode = parsedMap.nodes['sdk'];
    if (sdkNode != null) {
      // Lockfiles produced by pub versions from 1.14.0 through 1.18.0 included
      // a top-level "sdk" field which encoded the unified constraint on the
      // Dart SDK. They had no way of specifying constraints on other SDKs.
      sdkConstraints["dart"] = _parseVersionConstraint(sdkNode);
    } else if (parsedMap.containsKey('sdks')) {
      var sdksField = parsedMap['sdks'];
      _validate(sdksField is Map, 'The "sdks" field must be a mapping.',
          parsedMap.nodes['sdks']);

      sdksField.nodes.forEach((name, constraint) {
        _validate(name.value is String, 'SDK names must be strings.', name);
        sdkConstraints[name.value as String] =
            _parseVersionConstraint(constraint);
      });
    }

    var packages = <String, PackageId>{};
    var packageEntries = parsedMap['packages'];
    if (packageEntries != null) {
      _validate(packageEntries is Map, 'The "packages" field must be a map.',
          parsedMap.nodes['packages']);

      packageEntries.forEach((name, spec) {
        // Parse the version.
        _validate(spec.containsKey('version'),
            'Package $name is missing a version.', spec);
        var version = Version.parse(spec['version']);

        // Parse the source.
        _validate(spec.containsKey('source'),
            'Package $name is missing a source.', spec);
        var sourceName = spec['source'];

        _validate(spec.containsKey('description'),
            'Package $name is missing a description.', spec);
        var description = spec['description'];

        // Let the source parse the description.
        var source = sources[sourceName];
        PackageId id;
        try {
          id = source.parseId(name, version, description,
              containingPath: filePath);
        } on FormatException catch (ex) {
          throw SourceSpanFormatException(
              ex.message, spec.nodes['description'].span);
        }

        // Validate the name.
        _validate(name == id.name,
            "Package name $name doesn't match ${id.name}.", spec);

        packages[name] = id;
      });
    }

    return LockFile._(
        packages,
        sdkConstraints,
        const UnmodifiableSetView.empty(),
        const UnmodifiableSetView.empty(),
        const UnmodifiableSetView.empty());
  }

  /// Asserts that [node] is a version constraint, and parses it.
  static VersionConstraint _parseVersionConstraint(YamlNode node) {
    if (node == null) return null;

    _validate(node.value is String,
        'Invalid version constraint: must be a string.', node);

    return _wrapFormatException('version constraint', node.span,
        () => VersionConstraint.parse(node.value));
  }

  /// Runs [fn] and wraps any [FormatException] it throws in a
  /// [SourceSpanFormatException].
  ///
  /// [description] should be a noun phrase that describes whatever's being
  /// parsed or processed by [fn]. [span] should be the location of whatever's
  /// being processed within the pubspec.
  static _wrapFormatException(String description, SourceSpan span, fn()) {
    try {
      return fn();
    } on FormatException catch (e) {
      throw SourceSpanFormatException(
          'Invalid $description: ${e.message}', span);
    }
  }

  /// If [condition] is `false` throws a format error with [message] for [node].
  static void _validate(bool condition, String message, YamlNode node) {
    if (condition) return;
    throw SourceSpanFormatException(message, node.span);
  }

  /// Returns a copy of this LockFile with a package named [name] removed.
  ///
  /// Returns an identical [LockFile] if there's no package named [name].
  LockFile removePackage(String name) {
    if (!this.packages.containsKey(name)) return this;

    var packages = Map<String, PackageId>.from(this.packages);
    packages.remove(name);
    return LockFile._(packages, sdkConstraints, _mainDependencies,
        _devDependencies, _overriddenDependencies);
  }

  /// Returns the contents of the `.packages` file generated from this lockfile.
  ///
  /// If [entrypoint] is passed, a relative entry is added for its "lib/"
  /// directory, and [entrypoint] is added as default package name.
  Future<String> packagesFile(
    SystemCache cache, [
    String entrypoint,
    VersionConstraint entrypointSdkConstraint,
  ]) async {
    var header = "Generated by pub on ${DateTime.now()}.";

    final map = <String, Uri>{};
    for (final name in ordered(packages.keys)) {
      final id = packages[name];
      final source = cache.source(id.source);
      final pubspec = await source.describe(id);
      final sdkConstraint = pubspec.sdkConstraints[sdk.identifier];
      final languageVersion = _languageVersion(sdkConstraint);
      map[name] = p.toUri(p.join(source.getDirectory(id), "lib")).replace(
            fragment: 'dart=' + Uri.encodeQueryComponent('$languageVersion'),
          );
    }

    if (entrypoint != null) {
      final languageVersion = _languageVersion(entrypointSdkConstraint);
      map[entrypoint] = Uri(
        path: 'lib/',
        fragment: 'dart=' + Uri.encodeQueryComponent('$languageVersion'),
      );
      map[''] = Uri.parse(entrypoint);
    }

    var text = StringBuffer();
    packages_file.write(text, map, comment: header, allowDefaultPackage: true);
    return text.toString();
  }

  /// Returns the serialized YAML text of the lock file.
  ///
  /// [packageDir] is the containing directory of the root package, used to
  /// properly serialize package descriptions.
  String serialize(String packageDir) {
    // Convert the dependencies to a simple object.
    var packageMap = {};
    packages.forEach((name, package) {
      var description =
          package.source.serializeDescription(packageDir, package.description);

      packageMap[name] = {
        'version': package.version.toString(),
        'source': package.source.name,
        'description': description,
        'dependency': _dependencyType(package.name)
      };
    });

    var data = {
      'sdks': mapMap(sdkConstraints,
          value: (_, constraint) => constraint.toString()),
      'packages': packageMap
    };
    return """
# Generated by pub
# See https://dart.dev/tools/pub/glossary#lockfile
${yamlToString(data)}
""";
  }

  /// Returns the dependency classification for [package].
  String _dependencyType(String package) {
    if (_mainDependencies.contains(package)) return 'direct main';
    if (_devDependencies.contains(package)) return 'direct dev';

    // If a package appears in `dependency_overrides` and another dependency
    // section, the main section it appears in takes precedence.
    if (_overriddenDependencies.contains(package)) {
      return 'direct overridden';
    }
    return 'transitive';
  }
}

/// Extract the _language version_ from an SDK constraint in `pubspec.yaml`.
Version _languageVersion(VersionConstraint c) {
  if (c == null || c.isEmpty) {
    // If we have no language version, we shall use the version of the current
    // SDK processing the 'pubspec.yaml' file.
    return sdk.version;
  }
  if (c is Version) {
    return c;
  }
  if (c is VersionRange) {
    return c.min ?? sdk.version;
  }
  if (c is VersionUnion) {
    // `ranges` is non-empty and sorted.
    return c.ranges.first.min ?? sdk.version;
  }
  throw ArgumentError('Unknown VersionConstraint type $c.');
}
