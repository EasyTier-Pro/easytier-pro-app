part of 'workspace_home_view.dart';

extension _WorkspaceHomeNavigation on _WorkspaceHomeViewState {
  static const double _mobileSwipeDistanceThreshold = 72;
  static const double _mobileSwipeHorizontalDominance = 1.25;

  void _openNetworkDetail(ConsoleNetwork network) {
    _updateState(() {
      _selectedNetworkId = network.id;
      _activeView = _DashboardView.network;
      _resetNetworkDetailScrollOffset();
    });
    _refreshPeerPolling();
    unawaited(_loadSingleNetworkDevices(network.id));
    unawaited(_loadNetworkDetailData(network.id));
  }

  void _showOverview() {
    _updateState(() {
      _activeView = _DashboardView.overview;
    });
    _refreshPeerPolling();
  }

  void _showNetwork() {
    String? networkId;
    _updateState(() {
      if (_selectedNetworkId == null && _networks.isNotEmpty) {
        _selectedNetworkId = _networks.first.id;
      }
      networkId = _selectedNetworkId;
      _activeView = _DashboardView.network;
      _resetNetworkDetailScrollOffset();
    });
    _refreshPeerPolling();
    if (networkId != null) {
      unawaited(_loadSingleNetworkDevices(networkId!));
      unawaited(_loadNetworkDetailData(networkId!));
    }
  }

  void _selectNetwork(String networkId) {
    _updateState(() {
      _selectedNetworkId = networkId;
      _activeView = _DashboardView.network;
      _resetNetworkDetailScrollOffset();
    });
    _refreshPeerPolling();
    unawaited(_loadSingleNetworkDevices(networkId));
    unawaited(_loadNetworkDetailData(networkId));
  }

  void _showDevices() {
    _updateState(() {
      _activeView = _DashboardView.devices;
    });
    _refreshPeerPolling();
    if (!_isLoadingDevices) {
      unawaited(_loadManagedDevices());
    }
  }

  void _showSettings() {
    _updateState(() {
      _activeView = _DashboardView.settings;
    });
    _refreshPeerPolling();
  }

  void _handleMobilePageSwipe(Offset delta) {
    final horizontalDistance = delta.dx.abs();
    final verticalDistance = delta.dy.abs();
    if (horizontalDistance < _mobileSwipeDistanceThreshold ||
        horizontalDistance <
            verticalDistance * _mobileSwipeHorizontalDominance) {
      return;
    }

    final currentIndex = _mobileDashboardViewOrder.indexOf(_activeView);
    if (currentIndex < 0) {
      return;
    }

    final nextIndex = delta.dx < 0 ? currentIndex + 1 : currentIndex - 1;
    if (nextIndex < 0 || nextIndex >= _mobileDashboardViewOrder.length) {
      return;
    }

    _showMobileView(_mobileDashboardViewOrder[nextIndex]);
  }

  void _showMobileView(_DashboardView view) {
    switch (view) {
      case _DashboardView.overview:
        _showOverview();
      case _DashboardView.network:
        _showNetwork();
      case _DashboardView.devices:
        _showDevices();
      case _DashboardView.settings:
        _showSettings();
    }
  }
}
