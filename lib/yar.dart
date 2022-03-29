import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:collection/collection.dart';

typedef RedirectCallback = String? Function(String path);

/// [YarRouter.builder] typedef for building a widget related to a page
typedef YarWidgetBuilder = Widget Function(
  BuildContext context,
  YarRouteState info,
);

typedef SavedStateTransform<T> = T Function(dynamic data);

typedef OnRouteChangedCallback = void Function(String);

extension on String {
  Uri get uri => Uri.parse(this);
}

extension _ObjectX<T> on T {
  void run(void Function(T it) block) {
    block(this);
  }
}

extension YarRouterX on BuildContext {
  /// Extension on [IYarRouter]
  IYarRouter get router => YarRouter._of(this)!;
}

/// Info passed in [YarWidgetBuilder] when building a widget
class YarRouteState {
  const YarRouteState({
    this.argument,
    this.params = const <String, String>{},
  });

  /// Option argument pass for this route
  /// *Must be json encodable*
  final Object? argument;

  /// Params matches in the path
  ///
  /// ```dart
  ///
  /// FlRoute(
  ///   path: '/movies/:id/details',
  ///   builder: (context, info) {
  ///    final movieId = info.params['id'];
  ///   }
  /// )
  ///
  /// context.router.push('movies/1/details');
  ///
  /// ```
  final Map<String, String> params;
}

/// Registers a route for [IYarRouter]
class YarRoute<T> {
  YarRoute({
    /// Path for the route
    required String path,
    required this.builder,
    this.savedStateTransform,
    this.redirect,
  }) : uri = path.uri;

  /// Path related to this route
  final Uri uri;

  /// Returns a widget that corresponds to a page for matching this [uri]
  final YarWidgetBuilder builder;

  /// *Only for web*
  /// When passing an argument to a route if web's history stack is use
  /// transforms the object back to its original type
  ///
  /// The data will be compatible with json (null is possible)
  ///
  /// Related [json.decode]
  final SavedStateTransform<T>? savedStateTransform;

  /// Provide this callback if you want to handle redirect
  ///
  /// For example handling if the user is authorized to visit this page
  final RedirectCallback? redirect;

  @override
  String toString() {
    return 'FlRoute(uri= $uri)';
  }
}

/// Inner route state object holding information about the current navigation stack
class _YarRouteState {
  const _YarRouteState(
    this.uri,
    this.data, {
    required this.router,
    this.savedStateTransform,
  });

  /// Uri of the pushed route as provided by [IYarRouter.push]
  final Uri uri;

  /// Optional argument passed to this route
  final Object? data;

  /// Router that is related to this route
  ///
  /// Used for restoring state on the **web**
  final YarRouterState router;

  /// View [YarRoute.savedStateTransform]
  final SavedStateTransform? savedStateTransform;

  @override
  String toString() {
    return '_FlRouteState(uri= $uri, data= $data, routerName= ${router.name})';
  }
}

class _YarRouterParser extends RouteInformationParser<_YarRouteState> {
  _YarRouterParser(
    this.router,
  );

  final YarRouterState router;

  @override
  Future<_YarRouteState> parseRouteInformation(
    RouteInformation routeInformation,
  ) {
    final state = routeInformation.state != null
        ? json.decode(routeInformation.state as String)
        : null;

    YarRouterState getEffectiveRouter() {
      if (state != null && state['__meta']['routerName'] != '') {
        return router.getSubRouterRecursively(
            state['__meta']['routerName'] as String) as YarRouterState;
      }

      return router;
    }

    final effectiveRouter = getEffectiveRouter();

    return SynchronousFuture(
      _YarRouteState(
        routeInformation.location!.uri,
        state?['data'] != null
            ? effectiveRouter
                ._getFlRouteFromUri(routeInformation.location!.uri)
                ?.savedStateTransform
                ?.call(state['data'])
            : null,
        router: effectiveRouter,
      ),
    );
  }

  @override
  RouteInformation? restoreRouteInformation(_YarRouteState configuration) {
    // Save the name of the router for this configuration
    // to properly restore the state on [parseRouteInformation]
    final meta = {
      '__meta': {'routerName': configuration.router.name}
    };

    return RouteInformation(
      location: configuration.uri.toString(),
      state: configuration.savedStateTransform != null
          ? json.encode({'data': configuration.data, ...meta})
          : json.encode(meta),
    );
  }
}

class _YarRouteObserver with NavigatorObserver {
  _YarRouteObserver(this.onRouteChanged);

  final OnRouteChangedCallback onRouteChanged;

  void _onRouteChanged(Route route) =>
      Future.microtask(() => onRouteChanged(route.settings.name!));

  @override
  void didPush(Route route, Route? previousRoute) {
    _onRouteChanged(route);
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    if (previousRoute != null) {
      _onRouteChanged(previousRoute);
    }
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    if (newRoute != null) {
      _onRouteChanged(newRoute);
    }
  }
}

class _YarRouterDelegate extends RouterDelegate<_YarRouteState>
    with ChangeNotifier, PopNavigatorRouterDelegateMixin<_YarRouteState> {
  _YarRouterDelegate(
    this._router,
    this._optInCurrentConfiguration,
    this._onRouteChanged,
  );

  @override
  final navigatorKey = GlobalKey<NavigatorState>();

  final YarRouterState _router;

  /// Only the root delegate should opt in
  final bool _optInCurrentConfiguration;

  final OnRouteChangedCallback? _onRouteChanged;

  late final _observer = _onRouteChanged != null
      ? <NavigatorObserver>[_YarRouteObserver(_onRouteChanged!)]
      : const <NavigatorObserver>[];

  @override
  Widget build(BuildContext context) {
    if (_router._pages.isEmpty) {
      return const SizedBox();
    }

    return Navigator(
      key: navigatorKey,
      pages: _router._pages,
      observers: _observer,
      onPopPage: (page, result) {
        if (!page.didPop(result)) {
          return false;
        }

        _router.pop();

        return true;
      },
    );
  }

  void _onPagesChanged() => notifyListeners();

  @override
  Future<void> setNewRoutePath(_YarRouteState configuration) {
    if (configuration.router.hasRoute(configuration.uri.path)) {
      configuration.router.popUntil(configuration.uri.path);
      return SynchronousFuture(null);
    }

    return SynchronousFuture(
      configuration.router.push(
        configuration.uri.toString(),
        configuration.data,
      ),
    );
  }

  @override
  _YarRouteState? get currentConfiguration {
    if (!_optInCurrentConfiguration) {
      return null;
    }

    return _router._routeStateStack.lastOrNull;
  }
}

abstract class IYarRouter {
  /// Adds a new route to navigation stack
  void push(String path, [Object? data]);

  /// Replaces the top most route with a new one
  void replace(String path, [Object? data]);

  /// Removes the top most route
  void pop();

  /// Removes all route until it meets a route with [path]
  void popUntil(String path);

  /// Removes all routes until it meets [replacePath] and then pushes a new route with [newPath]
  void popUntilAndPush(String replacePath, String newPath, [Object? data]);

  /// Checks if a route with [path] exists
  bool hasRoute(String path);

  /// Returns a [IYarRouter] that is direct child of the current router
  IYarRouter? getSubRouter(String name);
}

class YarRouter extends StatefulWidget {
  const YarRouter({
    Key? key,
    required this.routes,
    required this.builder,
    this.redirect,
    this.onRouteChanged,
    this.unknownRouteBuilder,
  })  : _name = '',
        initialRoute = null,
        super(key: key);

  const YarRouter._subRouter(
    this._name, {
    Key? key,
    required this.routes,
    required this.builder,
    required this.redirect,
    this.initialRoute,
    this.onRouteChanged,
    this.unknownRouteBuilder,
  }) : super(key: key);

  /// Routes for this router
  final List<YarRoute> routes;

  /// A specialized case for [YarRoute.redirect]
  final RedirectCallback? redirect;

  /// Uses for subroutes to uniquely identify
  final String _name;

  final String? initialRoute;

  /// Callback builder that provides a parser and delegate for usage with
  /// [MaterialApp.router] or CupertinoApp.router
  final Widget Function(
    _YarRouterParser parser,
    _YarRouterDelegate delegate,
  ) builder;

  /// Called everytime the route changes providing the latest path
  final OnRouteChangedCallback? onRouteChanged;

  final Widget Function()? unknownRouteBuilder;

  static YarRouterState? _of(BuildContext context) {
    return context.findAncestorStateOfType<YarRouterState>();
  }

  static YarRouterState? _root(BuildContext context) {
    return context.findRootAncestorStateOfType<YarRouterState>();
  }

  @override
  YarRouterState createState() => YarRouterState();
}

class YarRouterState extends State<YarRouter> implements IYarRouter {
  late final _parser = _YarRouterParser(this);

  late final _delegate = _YarRouterDelegate(
    this,
    _getRootRouter() == this,
    widget.onRouteChanged,
  );

  final _subrouters = <YarRouterState>{};

  late final YarRouterState? _parentRouter = YarRouter._of(context);

  final _routeStateStack = ListQueue<_YarRouteState>();

  var _navStack = ListQueue<_YarRouteState>();

  var _pages = <Page>[];

  /// when a redirect occurs stop current [_isRouteMatch]
  var _earlyExitBuildPages = false;

  @override
  void initState() {
    super.initState();

    if (widget.initialRoute != null) {
      scheduleMicrotask(() => _push(widget.initialRoute!));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _registerAsSubRouter();
  }

  @override
  void didUpdateWidget(covariant YarRouter oldWidget) {
    super.didUpdateWidget(oldWidget);
    _buildPages();
  }

  @override
  void dispose() {
    _unregisterAsSubRouter();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(
      _parser,
      _delegate,
    );
  }

  YarRouterState _getRootRouter() => YarRouter._root(context) ?? this;

  String get name => widget._name;

  static bool _isRouteMatch(Uri uri1, Uri uri2) {
    if (uri1.pathSegments.length != uri2.pathSegments.length) {
      return false;
    }

    for (var i = 0; i < uri1.pathSegments.length; ++i) {
      final seg1 = uri1.pathSegments[i];
      final seg2 = uri2.pathSegments[i];

      if (seg1 != seg2 && seg1[0] != ':') {
        return false;
      }
    }
    return true;
  }

  YarRoute? _getFlRouteFromUri(Uri uri) {
    return widget.routes.firstWhereOrNull(
      (r) => _isRouteMatch(r.uri, uri),
    );
  }

  void _buildPages() {
    var pages = <Page>[];

    for (final routeState in [..._navStack]) {
      final route = _getFlRouteFromUri(routeState.uri);

      if (route != null) {
        final pageWidget = route.builder(
          context,
          YarRouteState(
            argument: routeState.data,
          ),
        );

        pages.add(
          MaterialPage(
            key: ValueKey(routeState.uri.toString()),
            child: pageWidget,
            name: routeState.uri.toString(),
          ),
        );
      }

      if (_earlyExitBuildPages) {
        _earlyExitBuildPages = false;
        return;
      }
    }

    _pages = pages;
    _delegate._onPagesChanged();
  }

  void _push(
    String path, {
    Object? data,
  }) {
    final route = _getFlRouteFromUri(path.uri);

    final redirectPath = (route?.redirect ?? widget.redirect)?.call(path);

    if (redirectPath != null) {
      _redirect(redirectPath);
      return;
    } else if (route == null) {
      return;
    }

    final pathUri = path.uri;

    final routeStateToRemove =
        _navStack.firstWhereOrNull((routeState) => routeState.uri == pathUri);

    if (routeStateToRemove != null) {
      _navStack.remove(routeStateToRemove);
    }

    final routeState = _YarRouteState(
      pathUri,
      data,
      router: this,
      savedStateTransform: route.savedStateTransform,
    );

    _navStack.addLast(routeState);
    _buildPages();

    _getRootRouter().run((it) {
      it
        .._routeStateStack.addLast(routeState)
        .._buildPages();
    });
  }

  @override
  void push(String path, [Object? data]) {
    _push(path, data: data);
  }

  @override
  void replace(String path, [Object? data]) {
    _YarRouteState? routeState;
    if (_navStack.isNotEmpty) {
      routeState = _navStack.removeLast();
    }

    _push(path, data: data);

    _getRootRouter().run((it) {
      it
        .._routeStateStack.remove(routeState)
        .._delegate._onPagesChanged();
    });
  }

  @override
  void pop() {
    if (_navStack.isNotEmpty) {
      final routeState = _navStack.removeLast();

      _buildPages();

      _getRootRouter().run((it) {
        it
          .._routeStateStack.remove(routeState)
          .._delegate._onPagesChanged();
      });
    }
  }

  @override
  bool hasRoute(String path) {
    final uri = path.uri;
    return _navStack.any((route) => route.uri == uri);
  }

  @override
  void popUntil(String path) {
    final uri = path.uri;

    final navStack = ListQueue<_YarRouteState>.from(_navStack);

    while (navStack.isNotEmpty && navStack.last.uri != uri) {
      final routeState = navStack.removeLast();

      _getRootRouter().run((it) => it._routeStateStack.remove(routeState));
    }

    _navStack = navStack;
    _buildPages();

    _getRootRouter().run((it) => it.._delegate._onPagesChanged());
  }

  @override
  void popUntilAndPush(String replacePath, String newPath, [Object? data]) {
    final replaceUri = replacePath.uri;

    final navStack = ListQueue<_YarRouteState>.from(_navStack);

    while (navStack.isNotEmpty && navStack.last.uri != replaceUri) {
      final routeState = navStack.removeLast();

      _getRootRouter().run((it) => it._routeStateStack.remove(routeState));
    }

    _navStack = navStack;
    _push(newPath, data: data);

    _getRootRouter().run((it) => it.._delegate._onPagesChanged());
  }

  void _redirect(String path) {
    _earlyExitBuildPages = true;
    replace(path);
  }

  void _registerAsSubRouter() {
    _parentRouter?._subrouters.add(this);
  }

  void _unregisterAsSubRouter() {
    _parentRouter?._subrouters.remove(this);
  }

  /// returns a direct [IYarRouter] of this [IYarRouter]
  @override
  IYarRouter? getSubRouter(String name) {
    return _subrouters.firstWhereOrNull((subrouter) => subrouter.name == name);
  }

  /// returns a [IYarRouter] visiting all subrouters below this router
  IYarRouter? getSubRouterRecursively(String name) {
    IYarRouter? visitSubRouter(YarRouterState router) {
      for (final subrouter in router._subrouters) {
        if (subrouter.name == name) {
          return subrouter;
        }

        final matchedRouter = visitSubRouter(subrouter);

        if (matchedRouter != null) {
          return matchedRouter;
        }
      }

      return null;
    }

    return visitSubRouter(this);
  }
}

/// Registers a subrouter that has it's own rendering area
class YarSubRouter extends StatelessWidget {
  const YarSubRouter({
    Key? key,
    required this.routes,
    required this.name,
    required this.initialPath,
    this.redirect,
    this.onRouteChanged,
  }) : super(key: key);

  /// A unique name for this subrouter
  ///
  /// The name can give used to find this router from a parent router
  ///
  /// ```dart
  /// context.router
  ///   .getSubRouter('my-subrouter')
  ///   .push('/new-route');
  /// ```
  final String name;

  /// Routes for this subrouter
  final List<YarRoute> routes;

  /// A specialized case for [YarRoute.redirect]
  final RedirectCallback? redirect;

  /// Initial path for this subrouter
  ///
  /// It's required as each router has it's **own navigation stack**
  final String initialPath;

  final OnRouteChangedCallback? onRouteChanged;

  @override
  Widget build(BuildContext context) {
    return YarRouter._subRouter(
      name,
      key: Key(name),
      routes: routes,
      redirect: redirect,
      initialRoute: initialPath,
      onRouteChanged: onRouteChanged,
      builder: (parser, delegate) {
        return Router(
          routerDelegate: delegate,
        );
      },
    );
  }
}
