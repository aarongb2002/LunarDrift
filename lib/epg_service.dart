import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

class EpgProgram {
  final String title;
  final String description;
  final DateTime start;
  final DateTime stop;

  EpgProgram({required this.title, required this.description, required this.start, required this.stop});
}

class EpgService {
  static final EpgService _instance = EpgService._internal();
  factory EpgService() => _instance;
  EpgService._internal();

  Map<String, List<EpgProgram>> epgDatabase = {};
  bool isLoaded = false;

  EpgProgram? getCurrentProgram(String? epgId) {
    if (epgId == null || !epgDatabase.containsKey(epgId)) return null;
    final now = DateTime.now().toUtc();
    try {
      return epgDatabase[epgId]!.firstWhere((p) => now.isAfter(p.start) && now.isBefore(p.stop));
    } catch (_) {
      return null;
    }
  }

  Future<void> fetchAndParseEPG({Set<String>? interestedChannelIds}) async {
    debugPrint('EpgService: Downloading optimized guide dictionary from Apache...');
    
    // Simply reference your domain name or VPS server IP where Apache is running
    final url = Uri.parse('https://lunardrift.watch/epg.json');
    
    try {
      final response = await http.get(url).timeout(const Duration(seconds: 20));

      if (response.statusCode == 200) {
        final Map<String, dynamic> decodedData = jsonDecode(response.body);
        Map<String, List<EpgProgram>> temporaryDb = {};

        decodedData.forEach((channelId, programList) {
          List<EpgProgram> channelPrograms = [];
          for (var item in programList) {
            channelPrograms.add(
              EpgProgram(
                title: item['title'],
                description: item['desc'],
                start: DateTime.parse(item['start']),
                stop: DateTime.parse(item['stop']),
              ),
            );
          }
          temporaryDb[channelId] = channelPrograms;
        });

        epgDatabase = temporaryDb;
        isLoaded = true;
        debugPrint('EpgService: Local app EPG database sync complete.');

        // Mapping of local EPG IDs to epg.pw numeric channel IDs for targeted updates
        const Map<String, String> customPWSources = {
          'WABCTV71.us': '464941',
          'WFORTV41.us': '464964',
          'CW.us': '464974',
          'WSVN71.us': '465011',
          'FoxSports1.us': '465005',
          'FoxSports2.us': '465006',
          'IONTV.us': '465030',
          'NBATV.us': '465057',
          'WNBC471.us': '467015',
          'truTV.us': '465122',
          'SpectrumSportsNet.us': '465252',
          'SpectrumSportsNetLA.us': '465251',
          'SkySportsF1.uk': '466858',
          'TNT.us': '465114',
          'TBS.us': '465285',
        };

        // Iterate and fetch overrides for interested channels to keep the guide accurate
        for (var entry in customPWSources.entries) {
          if (interestedChannelIds == null || interestedChannelIds.contains(entry.key)) {
            await _fetchCustomEpgPw(entry.key, entry.value);
          }
        }
      }
    } catch (e) {
      debugPrint('EpgService: Connection error reading from remote Apache instance: $e');
    }
  }

  /// Fetches EPG data for a specific channel from epg.pw API as an override source
  Future<void> _fetchCustomEpgPw(String targetEpgId, String pwChannelId) async {
    // We use yyyyMMdd format and UTC time to match what epg.pw expects for daily guides
    final dateStr = DateFormat('yyyyMMdd').format(DateTime.now().toUtc());
    final url = Uri.parse('https://epg.pw/api/epg.json?lang=en&date=$dateStr&channel_id=$pwChannelId');
    
    try {
      final response = await http.get(url);

      if (response.statusCode == 200) {
        final Map<String, dynamic> decodedData = jsonDecode(response.body);
        if (decodedData.containsKey(pwChannelId)) {
          final List programList = decodedData[pwChannelId];
          List<EpgProgram> channelPrograms = [];
          for (var item in programList) {
            channelPrograms.add(
              EpgProgram(
                title: item['title'] ?? 'Unknown',
                description: item['desc'] ?? '',
                start: DateTime.parse(item['start']),
                stop: DateTime.parse(item['stop']),
              ),
            );
          }
          epgDatabase[targetEpgId] = channelPrograms;
          debugPrint('EpgService: Custom EPG for $targetEpgId (Source: epg.pw) updated.');
        }
      }
    } catch (e) {
      debugPrint('EpgService: Failed to fetch custom EPG from epg.pw for $targetEpgId: $e');
    }
  }
}