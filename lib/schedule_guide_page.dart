import 'package:flutter/material.dart';
import 'live_tv_page.dart';
import 'epg_service.dart';
// ignore: unused_import
import 'main.dart';

class ScheduleGuidePage extends StatefulWidget {
  const ScheduleGuidePage({super.key});

  @override
  State<ScheduleGuidePage> createState() => _ScheduleGuidePageState();
}

class _ScheduleGuidePageState extends State<ScheduleGuidePage> {
  final _api = LiveSportsApi();
  bool _isLoading = true;
  // ignore: unused_field
  List<Sport> _sports = [];
  List<Match> _allMatches = [];

  @override
  void initState() {
    super.initState();
    
    // Immediately load from cache if available
    if (_api.hasPrefetched) {
      _allMatches = _api.cachedMatches.where((m) => !m.isLive && m.startTime.isAfter(DateTime.now())).toList();
      _isLoading = false;
    }

    _fetchData();
  }

  Future<void> _fetchData() async {
    try {
      final sports = await _api.fetchSports();
      
      // Fetch matches per sport sliver as requested
      final matchesResults = await Future.wait(
        sports.map((s) => _api.fetchMatches(sportSlug: s.slug))
      );

      // Ensure EPG is refreshed when the schedule is loaded/refreshed
      final interestedEpgIds = premiumChannelsList
          .map((m) => m.epgId)
          .whereType<String>()
          .toSet();

      await EpgService().fetchAndParseEPG(interestedChannelIds: interestedEpgIds);

      if (mounted) {
        final flatMatches = matchesResults.expand((m) => m).toList();
        _api.updateCache(sports, flatMatches);

        setState(() {
          _sports = sports;
          // Only show upcoming matches (not currently live and not finished)
          _allMatches = _api.cachedMatches.where((m) => !m.isLive && m.startTime.isAfter(DateTime.now())).toList();
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        debugPrint('Failed to load schedule: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: Color.fromARGB(255, 253, 254, 254)));
    }

    final Map<String, List<Match>> matchesBySport = {};
    for (var match in _allMatches) {
      matchesBySport.putIfAbsent(match.sport.name, () => []).add(match);
    }
    final sortedSports = matchesBySport.keys.toList()..sort();

    return RefreshIndicator(
      onRefresh: _fetchData,
      color: const Color.fromARGB(255, 249, 250, 250),
      backgroundColor: const Color(0xFF1E1F24),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: SizedBox(height: kToolbarHeight + MediaQuery.of(context).padding.top + 4),
          ),
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Schedule',
                  style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold)),
            ),
          ),
          const SliverToBoxAdapter(child: PremiumChannelGuide()),
          ...sortedSports.map((sportName) {
            return SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 16.0),
                child: HorizontalMatchList(
                  categoryTitle: sportName,
                  items: matchesBySport[sportName]!,
                ),
              ),
            );
          }),
          const SliverToBoxAdapter(child: SizedBox(height: 120)), // Padding for bottom nav bar
        ],
      ),
    );
  }
}
