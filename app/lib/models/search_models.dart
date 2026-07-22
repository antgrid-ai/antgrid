import 'package:flutter/foundation.dart';

@immutable
class SearchMatch {
  final int line;
  final int column;
  final String lineContent;
  final List<String> contextBefore;
  final List<String> contextAfter;

  const SearchMatch({
    required this.line,
    required this.column,
    required this.lineContent,
    required this.contextBefore,
    required this.contextAfter,
  });
}

@immutable
class SearchFileGroup {
  final String path;
  final List<SearchMatch> matches;

  const SearchFileGroup({required this.path, required this.matches});

  SearchFileGroup addMatches(List<SearchMatch> newMatches) {
    return SearchFileGroup(path: path, matches: [...matches, ...newMatches]);
  }
}

@immutable
class SearchState {
  final String query;
  final bool caseSensitive;
  final bool regex;
  final bool wholeWord;
  final bool isSearching;
  final String? currentRequestId;
  final List<SearchFileGroup> results;
  final int totalMatches;
  final int totalFiles;
  final int? duration;
  final String? engine;
  final String? error;

  const SearchState({
    this.query = '',
    this.caseSensitive = false,
    this.regex = false,
    this.wholeWord = false,
    this.isSearching = false,
    this.currentRequestId,
    this.results = const [],
    this.totalMatches = 0,
    this.totalFiles = 0,
    this.duration,
    this.engine,
    this.error,
  });

  SearchState copyWith({
    String? query,
    bool? caseSensitive,
    bool? regex,
    bool? wholeWord,
    bool? isSearching,
    String? currentRequestId,
    bool clearCurrentRequestId = false,
    List<SearchFileGroup>? results,
    int? totalMatches,
    int? totalFiles,
    int? duration,
    bool clearDuration = false,
    String? engine,
    bool clearEngine = false,
    String? error,
    bool clearError = false,
  }) {
    return SearchState(
      query: query ?? this.query,
      caseSensitive: caseSensitive ?? this.caseSensitive,
      regex: regex ?? this.regex,
      wholeWord: wholeWord ?? this.wholeWord,
      isSearching: isSearching ?? this.isSearching,
      currentRequestId: clearCurrentRequestId
          ? null
          : (currentRequestId ?? this.currentRequestId),
      results: results ?? this.results,
      totalMatches: totalMatches ?? this.totalMatches,
      totalFiles: totalFiles ?? this.totalFiles,
      duration: clearDuration ? null : (duration ?? this.duration),
      engine: clearEngine ? null : (engine ?? this.engine),
      error: clearError ? null : (error ?? this.error),
    );
  }
}
