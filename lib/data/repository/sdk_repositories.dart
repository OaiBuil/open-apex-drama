import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:openhongguo/openhongguo.dart';

import '../../models/catalog.dart';
import '../../models/danmaku_cue.dart';
import '../../models/drama.dart';
import '../../models/playback.dart';
import '../../models/search_results.dart';
import '../../models/series_detail.dart';
import '../mappers.dart';
import '../remote/openhongguo_service.dart';
import 'repositories.dart';

/// 基于水果端 SDK 的实现。
class SdkCatalogRepository implements CatalogRepository {
  SdkCatalogRepository({OpenhongguoService? service})
      : _service = service ?? OpenhongguoService.instance;

  final OpenhongguoService _service;

  Future<T> _guard<T>(Future<T> Function(OpenhongguoClient client) run) async {
    try {
      final OpenhongguoClient client = await _service.client();
      return await run(client);
    } catch (error) {
      throw OpenhongguoService.translate(error);
    }
  }

  @override
  Future<DramaPage> discoverFeed(String channelLabel, {String cursor = ''}) {
    final String? channel = kDiscoverChannels[channelLabel];
    if (channel == null) {
      throw UnsupportedError('频道「$channelLabel」暂未接入 SDK');
    }
    return _guard<DramaPage>((OpenhongguoClient client) async {
      final PagedResult<SeriesSummary> page = await client.discover(
        DiscoverOptions(
          channel: channel,
          cursor: cursor.isEmpty ? null : cursor,
        ),
      );
      debugPrint(
        '[discover:$channelLabel${cursor.isEmpty ? '' : ':cursor'}] '
        '${page.items.length} 部: '
        '${page.items.take(5).map((SeriesSummary s) => s.title).join(' / ')}',
      );
      return DramaPage(
        items: <Drama>[
          for (final SeriesSummary item in page.items)
            dramaFromSummary(item, kind: channelLabel),
        ],
        cursor: page.cursor,
        hasMore: page.hasMore && page.cursor.isNotEmpty,
      );
    });
  }



  @override
  Future<SearchPage> searchPage(
    String query, {
    String cursor = '',
    int pageSize = 20,
  }) {
    return _guard<SearchPage>((OpenhongguoClient client) async {
      final PagedResult<SeriesSummary> page = await client.search(
        query,
        SearchOptions(
          cursor: cursor.isEmpty ? null : cursor,
          pageSize: pageSize,
        ),
      );
      // 官方搜索页会混入帖子 / UGC 视频（episodeCount 为 0），它们不是剧集，
      // 点开详情会返回 101000 content_gone。搜索结果只保留有集数的条目。
      final List<SeriesSummary> dramas = <SeriesSummary>[
        for (final SeriesSummary item in page.items)
          if (item.episodeCount > 0) item,
      ];
      final Map<String, SeriesDetail> details = await _searchDetails(
        client,
        dramas,
      );
      await _primeSeasonCounts(client, dramas, details, query);
      return SearchPage(
        items: <Drama>[
          for (final SeriesSummary item in dramas)
            dramaFromSummary(
              item,
              coverUrl: details[item.id]?.series?.coverUrl,
              seasonCount: _seasonCountFor(item.id, details[item.id]),
            ),
        ],
        cursor: page.cursor,
        hasMore: page.hasMore && page.cursor.isNotEmpty,
      );
    });
  }

  /// 季数按合集 id 缓存：同合集的不同季、重复搜索都只查一次。
  final Map<String, int> _seasonCountCache = <String, int>{};

  /// 单页最多补几部剧的季数。seasons() 内部不止一次请求，而匿名设备的
  /// 目录额度有限，不能对每个结果都查。
  static const int _seasonCountProbeLimit = 3;

  /// 搜索接口不返回封面和多季标记（SDK 的 ParseSearch 只映射
  /// id/标题/简介/集数），直接渲染会整屏渐变色块、也看不出是否多季。
  /// 这里用一次 getSeriesBatch 批量补齐；失败时保持无封面，不影响结果本身。
  static Future<Map<String, SeriesDetail>> _searchDetails(
    OpenhongguoClient client,
    List<SeriesSummary> items,
  ) async {
    final List<String> ids = <String>[
      for (final SeriesSummary item in items)
        if (item.id.isNotEmpty) item.id,
    ];
    if (ids.isEmpty) {
      return const <String, SeriesDetail>{};
    }
    try {
      final List<SeriesDetail> details = await client.getSeriesBatch(ids);
      return <String, SeriesDetail>{
        for (final SeriesDetail detail in details)
          if (detail.series != null && detail.series!.id.isNotEmpty)
            detail.series!.id: detail,
      };
    } catch (_) {
      return const <String, SeriesDetail>{};
    }
  }

  /// 给「标题直接命中且确为多季」的结果补总季数，供卡片显示「共 N 季」。
  /// 只探测前几部：同名的不同制作版本都会各自给出季数。
  Future<void> _primeSeasonCounts(
    OpenhongguoClient client,
    List<SeriesSummary> items,
    Map<String, SeriesDetail> details,
    String query,
  ) async {
    final List<String> candidates = <String>[
      for (final SeriesSummary item in items)
        if (titleMatchesQuery(item.title, query) &&
            (details[item.id]?.series?.isMultiSeason ?? false) &&
            !_seasonCountCache.containsKey(_seasonKey(item.id, details[item.id])))
          item.id,
    ].take(_seasonCountProbeLimit).toList();
    await Future.wait<void>(<Future<void>>[
      for (final String id in candidates) _probeSeasonCount(client, id, details[id]),
    ]);
  }

  Future<void> _probeSeasonCount(
    OpenhongguoClient client,
    String seriesId,
    SeriesDetail? detail,
  ) async {
    try {
      final Album album = await client.seasons(seriesId);
      final int count = album.seasonCount > 0
          ? album.seasonCount
          : album.seasons.length;
      if (count > 1) {
        _seasonCountCache[_seasonKey(seriesId, detail)] = count;
      }
    } catch (_) {
      // 季接口失败不影响搜索结果本身，卡片不显示季数即可。
    }
  }

  String _seasonKey(String seriesId, SeriesDetail? detail) {
    final String albumId = detail?.series?.relatedAlbumId ?? '';
    return albumId.isEmpty ? seriesId : albumId;
  }

  int _seasonCountFor(String seriesId, SeriesDetail? detail) =>
      _seasonCountCache[_seasonKey(seriesId, detail)] ?? 0;

  @override
  Future<List<String>> suggest(String prefix) {
    return _guard<List<String>>((OpenhongguoClient client) async {
      final List<Suggestion> items = await client.suggest(prefix);
      return <String>[
        for (final Suggestion s in items) s.text.isEmpty ? s.keyword : s.text,
      ];
    });
  }

  @override
  Future<SearchHome> searchHome() {
    return _guard<SearchHome>((OpenhongguoClient client) async {
      final HotSearch hot = await client.hotSearch();
      return SearchHome(
        guesses: <SearchCandidate>[
          for (final HotItem item in hot.guesses)
            SearchCandidate(
              text: item.title,
              seriesId: item.seriesId,
              coverUrl: item.coverUrl,
              episodeCount: item.episodeCount,
            ),
        ],
        hotBoard: <SearchCandidate>[
          if (hot.boards.isNotEmpty)
            for (final HotItem item in hot.boards.first.items)
              SearchCandidate(
                text: item.title,
                seriesId: item.seriesId,
                coverUrl: item.coverUrl,
                episodeCount: item.episodeCount,
                score: item.searchScore,
              ),
        ],
      );
    });
  }

  @override
  Future<List<Drama>> categorySeries(String categoryId) {
    return _guard<List<Drama>>((OpenhongguoClient client) async {
      final CategoryPage page = await client.categoryLanding(categoryId);
      return <Drama>[
        for (final SeriesSummary item in page.items) dramaFromSummary(item),
      ];
    });
  }

  @override
  Future<DramaPage> filter({
    Map<String, List<String>>? selections,
    String cursor = '',
  }) {
    return _guard<DramaPage>((OpenhongguoClient client) async {
      final ShortFilterPage page = await client.shortFilter(
        ShortFilterQuery(
          selections: selections,
          cursor: cursor.isEmpty ? null : cursor,
        ),
      );
      return DramaPage(
        items: <Drama>[
          for (final SeriesSummary item in page.items) dramaFromSummary(item),
        ],
        cursor: page.cursor,
        hasMore: page.hasMore && page.cursor.isNotEmpty,
      );
    });
  }

  @override
  Future<List<FilterGroupData>> filterPanel() {
    return _guard<List<FilterGroupData>>((OpenhongguoClient client) async {
      final List<FilterRow> rows = await client.shortFilterPanel();
      return <FilterGroupData>[
        for (final FilterRow row in rows)
          FilterGroupData(
            key: row.key,
            name: row.name,
            options: <(String, String)>[
              for (final FilterOption option in row.options)
                (option.name, option.value),
            ],
          ),
      ];
    });
  }

  /// 详情聚合缓存：同一部剧反复进入时直接复用，避免重复消耗匿名目录额度，
  /// 也避免推荐位每次刷新出不同内容。过期后重新拉取，失败时退回旧数据。
  static const Duration _detailCacheTtl = Duration(minutes: 10);
  static const int _detailCacheLimit = 40;
  final Map<String, _CachedDetail> _detailCache = <String, _CachedDetail>{};
  final Map<String, _CachedFeed> _kindFeedCache = <String, _CachedFeed>{};

  @override
  Future<SeriesDetailData> seriesDetail(String seriesId) async {
    final _CachedDetail? cached = _detailCache[seriesId];
    if (cached != null && cached.isFresh) {
      return cached.data;
    }
    try {
      final SeriesDetailData data = await _guard<SeriesDetailData>((
        OpenhongguoClient client,
      ) async {
        // 先取详情确定类型；推荐、多季、同类型频道随后并行发出，
        // 不再等三个请求全部结束才补推荐。
        final Series series = await client.getSeries(seriesId);
        final String kind = kindForContentType(series.contentType.value);
        final Future<Recommend> recommendFuture = client.seriesRecommend(
          seriesId,
        );
        final Future<Album> albumFuture = client
            .seasons(seriesId)
            .catchError((Object _) => Album());
        final Future<List<Drama>> sameKindFuture = kind == '短剧'
            ? Future<List<Drama>>.value(const <Drama>[])
            : _discoverSameKind(client, kind);
        final Recommend recommend = await recommendFuture;
        final Album album = await albumFuture;
        final List<Drama> sameKind = await sameKindFuture;
        final _Recommendation recommendation = _recommendationFor(
          series: series,
          recommend: recommend,
          kind: kind,
          sameKind: sameKind,
        );
        return SeriesDetailData(
          drama: dramaFromSeries(series, kind: kind),
          seasons: <SeasonInfo>[
            for (final Season season in album.seasons)
              SeasonInfo(
                seriesId: season.seriesId,
                title: season.title,
                index: season.index,
                episodeCount: season.episodeCount,
              ),
          ],
          recommend: recommendation.items,
          recommendTitle: recommendation.title,
          isMultiSeason: series.isMultiSeason,
          relatedAlbumId: series.relatedAlbumId,
          payType: series.payType.value,
        );
      });
      _rememberDetail(seriesId, data);
      return data;
    } catch (_) {
      if (cached != null) {
        return cached.data;
      }
      rethrow;
    }
  }

  void _rememberDetail(String seriesId, SeriesDetailData data) {
    _detailCache[seriesId] = _CachedDetail(data);
    if (_detailCache.length <= _detailCacheLimit) {
      return;
    }
    // 超出上限时淘汰最旧的一条，避免长会话无限增长。
    String? oldestKey;
    DateTime? oldestAt;
    for (final MapEntry<String, _CachedDetail> entry in _detailCache.entries) {
      if (oldestAt == null || entry.value.at.isBefore(oldestAt)) {
        oldestAt = entry.value.at;
        oldestKey = entry.key;
      }
    }
    if (oldestKey != null) {
      _detailCache.remove(oldestKey);
    }
  }

  /// 统一处理详情页推荐：匿名接口固定回通用的「更多好剧」（与当前剧无关、
  /// 且恒为真人剧），非真人剧时改用同类型频道内容，替换不到就隐藏推荐区。
  static _Recommendation _recommendationFor({
    required Series series,
    required Recommend recommend,
    required String kind,
    required List<Drama> sameKind,
  }) {
    final String cellTitle = recommend.cellTitle.trim();
    final List<Drama> generic = <Drama>[
      for (final SeriesSummary item in recommend.items)
        if (item.id.isNotEmpty && item.id != series.id)
          dramaFromSummary(item),
    ];
    if (cellTitle != '更多好剧') {
      return _Recommendation(
        title: cellTitle.isEmpty ? '相关推荐' : cellTitle,
        items: generic,
      );
    }
    if (kind == '短剧') {
      return _Recommendation(title: cellTitle, items: generic);
    }
    final List<Drama> candidates = <Drama>[
      for (final Drama item in sameKind)
        if (item.id != series.id) item,
    ];
    if (candidates.isEmpty) {
      return const _Recommendation(title: '', items: <Drama>[]);
    }
    return _Recommendation(title: '更多$kind', items: candidates);
  }

  /// 按类型取首页频道内容当推荐；没有对应频道的类型（电视剧）返回空。
  /// 频道列表按类型缓存，连续打开漫剧/电影详情时推荐位不再重复等待。
  Future<List<Drama>> _discoverSameKind(
    OpenhongguoClient client,
    String kind,
  ) async {
    final String channel = switch (kind) {
      '漫剧' => '漫剧',
      '电影' => '电影',
      _ => '',
    };
    if (channel.isEmpty) {
      return const <Drama>[];
    }
    final _CachedFeed? cached = _kindFeedCache[kind];
    if (cached != null && cached.isFresh) {
      return cached.items;
    }
    try {
      final PagedResult<SeriesSummary> page = await client.discover(
        DiscoverOptions(channel: channel),
      );
      final List<Drama> items = <Drama>[
        for (final SeriesSummary item in page.items)
          if (item.id.isNotEmpty && item.episodeCount > 0)
            dramaFromSummary(item, kind: kind),
      ];
      _kindFeedCache[kind] = _CachedFeed(items);
      return items;
    } catch (_) {
      return cached?.items ?? const <Drama>[];
    }
  }

  @override
  Future<List<Drama>> newReleases({String? date}) {
    return _guard<List<Drama>>((OpenhongguoClient client) async {
      final NewReleasePage page = await client.newReleases(
        NewReleaseQuery(date: date),
      );
      return <Drama>[
        for (final NewRelease item in page.items)
          Drama(
            id: item.seriesId,
            title: item.title,
            kind: '短剧',
            category:
                item.categories.isNotEmpty ? item.categories.first : '短剧',
            tags: item.categories,
            episodes: item.episodeCount,
            rating: 0,
            viewers: '',
            description: item.description,
            coverColors: paletteFor(item.seriesId + item.title),
            coverUrl: item.coverUrl,
            episodeTitles: const <String>[],
            badge: publishBadge(item.publishAt),
          ),
      ];
    });
  }
}

/// 榜单：短剧榜（contents/boards 提供 Tab，items 提供条目）。
class SdkRankRepository implements RankRepository {
  SdkRankRepository({OpenhongguoService? service})
      : _service = service ?? OpenhongguoService.instance;

  final OpenhongguoService _service;

  @override
  Future<RankPage> rankPage({String? contentId, String? boardId}) async {
    try {
      final OpenhongguoClient client = await _service.client();
      final ShortRanking ranking = await client.shortRank(
        ShortRankQuery(content: contentId, board: boardId),
      );
      return RankPage(
        tabs: <RankTab>[
          for (final RankContent content in ranking.contents)
            for (final RankBoard board in content.boards)
              RankTab(
                label: board.name,
                contentId: content.id,
                boardId: board.id,
                selected: content.selected || board.selected,
              ),
        ],
        entries: <RankEntry>[
          // 注意用 position（页面名次，从 1 开始）而非 rank（服务端编号，
          // 推广行前后重复、推荐榜个性化、预约榜可能全 0——v1.1.0 显示
          // 1,1,2,3… 与全 0 的根因）。position 异常时回退行序。
          for (final (int index, RankItem item) in ranking.items.indexed)
            RankEntry(
              rank: item.position > 0
                  ? item.position
                  : (item.rank > 0 ? item.rank : index + 1),
              score: item.score,
              actor: item.actor,
              drama: dramaFromSummary(
                SeriesSummary(
                  id: item.seriesId,
                  title: item.title,
                  coverUrl: item.coverUrl,
                ),
              ),
            ),
        ],
      );
    } catch (error) {
      throw OpenhongguoService.translate(error);
    }
  }
}

/// 播放解析：按分集缓存结果（匿名设备额度有限，绝不重复解析）。
class SdkPlaybackRepository implements PlaybackRepository {
  SdkPlaybackRepository({OpenhongguoService? service})
      : _service = service ?? OpenhongguoService.instance;

  final OpenhongguoService _service;
  final Map<String, PlaybackBundle> _cache = <String, PlaybackBundle>{};

  Future<T> _guard<T>(Future<T> Function(OpenhongguoClient client) run) async {
    try {
      final OpenhongguoClient client = await _service.client();
      return await run(client);
    } catch (error) {
      throw OpenhongguoService.translate(error);
    }
  }

  @override
  Future<List<EpisodeInfo>> episodes(String seriesId) async {
    try {
      return await _guard<List<EpisodeInfo>>((OpenhongguoClient client) async {
        // listEpisodes 是分页接口（默认一页 20 条），必须按 cursor 翻页
        // 拉全，否则百集剧只显示首页 20 集。上限防御：单剧最多 50 页。
        final List<EpisodeInfo> all = <EpisodeInfo>[];
        String? cursor;
        for (int page = 0; page < 50; page++) {
          final PagedResult<Episode> result = await client.listEpisodes(
            seriesId,
            EpisodeOptions(cursor: cursor, pageSize: 100),
          );
          all.addAll(<EpisodeInfo>[
            for (final Episode e in result.items) episodeInfoFrom(e),
          ]);
          if (!result.hasMore || result.cursor.isEmpty) {
            break;
          }
          cursor = result.cursor;
        }
        return all;
      });
    } catch (error) {
      _logResolve('episodes fail series=$seriesId error=$error');
      rethrow;
    }
  }

  /// 解析重试退避：服务端播放接口会间歇性返回空结果或 5xx（实测成片出现，
  /// 几十秒后自愈），而 SDK 把空结果当成设备失效、每次都要换 2 台设备。
  /// App 侧先原地重试几次，能覆盖掉大部分抖动，避免直接给用户报错。
  static const List<Duration> _resolveBackoff = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 3),
    Duration(seconds: 6),
  ];

  /// 这些错误码属于「服务端一时取不到」，值得重试；其余（内容下架、
  /// 需要登录等）重试也不会变好。
  static bool _retryableResolve(String code) {
    switch (code) {
      case 'ANONYMOUS_LIMITED':
      case 'DEVICE_REJECTED':
      case 'TRANSPORT':
      case 'RATE_LIMITED':
        return true;
      default:
        return false;
    }
  }

  @override
  Future<PlaybackBundle> resolve(String episodeId) async {
    final PlaybackBundle? cached = _cache[episodeId];
    if (cached != null) {
      return cached;
    }
    for (int attempt = 0; ; attempt++) {
      try {
        final PlaybackBundle bundle = await _guard<PlaybackBundle>(
          (OpenhongguoClient client) async {
            final PlaybackResult result =
                await client.resolvePlayback(episodeId);
            return bundleFrom(result);
          },
        );
        if (bundle.streams.isNotEmpty) {
          _cache[episodeId] = bundle;
        }
        _logResolve(
          'ok episode=$episodeId streams=${bundle.streams.length}'
          '${attempt > 0 ? ' retry=$attempt' : ''}',
        );
        return bundle;
      } on ApiException catch (error) {
        _logResolve(
          'fail episode=$episodeId attempt=$attempt error=$error',
        );
        if (!_retryableResolve(error.code) ||
            attempt >= _resolveBackoff.length) {
          rethrow;
        }
        await Future<void>.delayed(_resolveBackoff[attempt]);
      }
    }
  }

  @override
  Future<List<DanmakuCue>> danmaku(String seriesId, String episodeId) async {
    try {
      return await _guard<List<DanmakuCue>>((OpenhongguoClient client) async {
        final List<DanmakuCue> cues = <DanmakuCue>[];
        String cursor = '';
        // 服务端按播放时间分 30 秒一段下发，一集通常 2~6 页；
        // 上限 30 页防止异常情况下无限翻页。
        for (int page = 0; page < 30; page++) {
          final DanmakuPage result = await client.listDanmaku(
            seriesId,
            episodeId,
            DanmakuOptions(cursor: cursor.isEmpty ? null : cursor),
          );
          for (final Danmaku item in result.items) {
            final String text = item.text.trim();
            if (text.isNotEmpty) {
              cues.add(DanmakuCue(text: text, offsetMs: item.offsetMs));
            }
          }
          if (!result.hasMore || result.cursor.isEmpty) {
            break;
          }
          if (result.cursor == cursor) {
            break; // 游标没有推进，避免死循环
          }
          cursor = result.cursor;
        }
        cues.sort((DanmakuCue a, DanmakuCue b) => a.offsetMs - b.offsetMs);
        return cues;
      });
    } catch (error) {
      _logResolve('danmaku fail series=$seriesId episode=$episodeId error=$error');
      return const <DanmakuCue>[];
    }
  }

  /// 播放解析诊断日志。写入系统临时目录的 `apex-resolve.log`。
  ///
  /// 线上「匿名设备次数已用尽」这类报错只有错误码，看不出是哪一集、
  /// 失败在分集列表还是播放解析上，出问题时要靠这份日志定位。
  static void _logResolve(String line) {
    final String stamp = DateTime.now().toIso8601String();
    debugPrint('[resolve] $line');
    try {
      File('${Directory.systemTemp.path}/apex-resolve.log').writeAsStringSync(
        '$stamp $line\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // 日志写失败不影响播放。
    }
  }
}

/// 带过期时间的详情缓存。
class _CachedDetail {
  _CachedDetail(this.data) : at = DateTime.now();

  final SeriesDetailData data;
  final DateTime at;

  bool get isFresh =>
      DateTime.now().difference(at) < SdkCatalogRepository._detailCacheTtl;
}

/// 带过期时间的频道列表缓存。
class _CachedFeed {
  _CachedFeed(this.items) : at = DateTime.now();

  final List<Drama> items;
  final DateTime at;

  bool get isFresh =>
      DateTime.now().difference(at) < SdkCatalogRepository._detailCacheTtl;
}

/// 详情页推荐区的最终内容与标题。
class _Recommendation {
  const _Recommendation({required this.title, required this.items});

  final String title;
  final List<Drama> items;
}
