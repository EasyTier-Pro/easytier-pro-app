part of 'workspace_home_view.dart';

extension _WorkspaceHomeNavigation on _WorkspaceHomeViewState {
  void _openNetworkDetail(ConsoleNetwork network) {
    _updateState(() {
      _selectedNetworkId = network.id;
      _activeView = _DashboardView.network;
    });
    _refreshPeerPolling();
    unawaited(_loadSingleNetworkDevices(network.id));
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
    });
    _refreshPeerPolling();
    if (networkId != null) {
      unawaited(_loadSingleNetworkDevices(networkId!));
    }
  }

  void _selectNetwork(String networkId) {
    _updateState(() {
      _selectedNetworkId = networkId;
      _activeView = _DashboardView.network;
    });
    _refreshPeerPolling();
    unawaited(_loadSingleNetworkDevices(networkId));
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
}
