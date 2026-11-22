import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/remote/openhongguo_service.dart';
import '../models/catalog.dart';
import '../models/drama.dart';
import '../providers/data_providers.dart';
import '../theme/app_colors.dart';
import '../widgets/ambient_glow.dart';
import '../widgets/app_icon_button.dart';
import '../widgets/app_pill_button.dart';
import '../widgets/drama_card.dart';
import '../widgets/empty_state.dart';
import '../widgets/page_layout.dart';
import '../widgets/soft_chip.dart';
import 'drama_detail_screen.dart';
import 'search_screen.dart';

class CategoryScreen extends ConsumerStatefulWidget {
  const CategoryScreen({super.key});

  @override
  ConsumerState<CategoryScreen> createState() => _CategoryScreenState();
}

class _CategoryScreenState extends ConsumerState<CategoryScreen> {
  /// 筛选行收纳：默认只露出第一组（体裁），其余收起、可一键展开。
  bool _filtersExpanded = false;
  /// 各筛选组选中的 value 集合；缺失或为空表示该组停留在「全部」（第一项）。
  final Map<String, Set<String>> _selected = <String, Set<String>>{};
  List<Drama> _more = const <Drama>[];
  String _moreCursor = '';
  bool _moreHasMore = false;
  String? _moreFor;
  bool _loadingMore = false;
  int _pagingGeneration = 0;

  void _onSearch() {
    openSearch(context);
  }

  /// 该组是否处于非「全部」的筛选状态（收纳时据此强制显示该组）。
  bool _hasSelection(FilterGroupData group) {
    return _selected[group.key]?.isNotEmpty ?? false;
  }

  /// 每组的选项列表：面板自带「全部」占位（首项 value 为空或 label 为「全部」）
  /// 时直接使用；否则在头部补一颗 value='' 的「全部」chip（即默认选中的第一项）。
  List<(String, String)> _optionsFor(FilterGroupData group) {
    if (group.options.isEmpty) {
      return const <(String, String)>[];
    }
    final (String firstLabel, String firstValue) = group.options.first;
    final bool hasAll = firstValue.isEmpty || firstLabel == '全部';
    if (hasAll) {
      return group.options;
    }
    return <(String, String)>[
      ('全部', ''),
      ...group.options,
    ];
  }

  bool _isSelected(FilterGroupData group, List<(String, String)> options, int index) {
    final Set<String>? values = _selected[group.key];
    if (values == null || values.isEmpty) {
      return index == 0;
    }
    return values.contains(options[index].$2);
  }

  void _toggle(FilterGroupData group, List<(String, String)> options, int index) {
    final String value = options[index].$2;
    setState(() {
      _resetPaging();
      // 每组第一项是「全部」（value 为空）：点击即回到该组不筛选的状态。
      if (index == 0 || value.isEmpty) {
        _selected.remove(group.key);
        return;
      }
      final Set<String> values = _selected.putIfAbsent(
        group.key,
        () => <String>{},
      );
      if (!values.add(value)) {
        values.remove(value);
      }
      if (values.isEmpty) {
        _selected.remove(group.key);
      }
    });
  }

  void _resetPaging() {
    _pagingGeneration++;
    _more = const <Drama>[];
    _moreCursor = '';
    _moreHasMore = false;
    _moreFor = null;
    _loadingMore = false;
  }

  Future<void> _loadMore(String selectionsKey, DramaPage firstPage) async {
    if (_loadingMore) {
      return;
    }
    final bool chained = _moreFor == selectionsKey;
    final String cursor = chained ? _moreCursor : firstPage.cursor;
    if (cursor.isEmpty) {
      return;
    }
    final int generation = _pagingGeneration;
    setState(() => _loadingMore = true);
    try {
      final DramaPage next = await ref
          .read(catalogRepositoryProvider)
          .filter(
            selections: filterSelectionsFromKey(selectionsKey),
            cursor: cursor,
          );
      if (!mounted || generation != _pagingGeneration) {
        return;
      }
      setState(() {
        final Set<String> seen = <String>{
          for (final Drama drama in firstPage.items) drama.id,
          for (final Drama drama in _more) drama.id,
        };
        _more = <Drama>[
          ..._more,
          for (final Drama drama in next.items)
            if (seen.add(drama.id)) drama,
        ];
        _moreFor = selectionsKey;
        _moreCursor = next.cursor;
        _moreHasMore =
            next.hasMore && next.cursor.isNotEmpty && next.cursor != cursor;
      });
    } on ApiException catch (error) {
      if (mounted && generation == _pagingGeneration) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(error.userMessage)));
      }
    } finally {
      if (mounted && generation == _pagingGeneration) {
        setState(() => _loadingMore = false);
      }
    }
  }

  /// 缓存键格式 `key=v1,v2;key2=v3`：组内 value 与组间 key 均按字典序排序，
  /// 相同选择无论点选先后都命中同一条缓存；全部不筛选时为空字符串。
  String _selectionsKey(List<FilterGroupData> groups) {
    final List<String> pairs = <String>[];
    for (final FilterGroupData group in groups) {
      final List<String> values = (_selected[group.key] ?? const <String>{})
          .where((String value) => value.isNotEmpty)
          .toList()
        ..sort();
      if (values.isEmpty) {
        continue;
      }
      pairs.add('${group.key}=${values.join(',')}');
    }
    pairs.sort();
    return pairs.join(';');
  }

  /// 结果区标题：各组选中项的 label 依序拼接。
  String _selectionTitle(List<FilterGroupData> groups) {
    final List<String> labels = <String>[];
    for (final FilterGroupData group in groups) {
      final Set<String> values = _selected[group.key] ?? const <String>{};
      for (final (String label, String value) in group.options) {
        if (value.isNotEmpty && values.contains(value)) {
          labels.add(label);
        }
      }
    }
    return labels.isEmpty ? '全部' : labels.join('/');
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = context.colors;
    final double horizontal = horizontalPagePadding(context);
    final double contentWidth = pageContentWidth(context);
    final int dramaColumns = dramaGridColumns(contentWidth);
    final double dramaWidth =
        (contentWidth - (dramaColumns - 1) * 11) / dramaColumns;
    final double dramaExtent = dramaWidth * 4 / 3 + 62;

    final AsyncValue<List<FilterGroupData>> panelAsync = ref.watch(
      filterPanelProvider,
    );
    final List<FilterGroupData>? groups = panelAsync.value;
    final String selectionsKey = groups == null ? '' : _selectionsKey(groups);
    final bool showingAll = selectionsKey.isEmpty;

    // 全部/筛选统一走筛选接口：空 selections 即全量真实短剧列表。
    final AsyncValue<DramaPage> resultAsync = ref.watch(
      filterResultProvider(selectionsKey),
    );
    final DramaPage? firstPage = resultAsync.value;
    final bool chained = _moreFor == selectionsKey;
    final List<Drama> dramas = <Drama>[
      ...?firstPage?.items,
      if (chained) ..._more,
    ];
    final bool hasMore =
        firstPage != null && (chained ? _moreHasMore : firstPage.hasMore);
    final bool resultLoading = resultAsync.isLoading && dramas.isEmpty;

    return AmbientGlow(
      child: SafeArea(
        bottom: false,
        child: CustomScrollView(
          slivers: <Widget>[
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(horizontal, 12, horizontal - 8, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            '分类',
                            style: TextStyle(
                              fontSize: 26,
                              height: 1.2,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.2,
                              color: colors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '按题材找到下一部想追的剧',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.3,
                              color: colors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    AppIconButton(
                      icon: Icons.search_rounded,
                      tooltip: '搜索',
                      onPressed: _onSearch,
                      size: 38,
                      iconSize: 22,
                      plain: true,
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(horizontal, 16, horizontal, 0),
              sliver: SliverToBoxAdapter(
                child: _buildPanel(context, panelAsync),
              ),
            ),
            // 全部与筛选共用同一剧集网格（数据源已统一）。
            if (showingAll || true) ...<Widget>[
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(horizontal, 22, horizontal, 12),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          showingAll
                              ? '全部短剧'
                              : '${_selectionTitle(groups ?? const <FilterGroupData>[])} · 精选短剧',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            height: 1.25,
                            fontWeight: FontWeight.w700,
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                      if (!resultLoading) ...<Widget>[
                        const SizedBox(width: 12),
                        Text(
                          hasMore
                              ? '已显示 ${dramas.length} 部'
                              : '共 ${dramas.length} 部',
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.2,
                            color: colors.textTertiary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (resultLoading)
                SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: horizontal),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: dramaColumns,
                      mainAxisSpacing: 18,
                      crossAxisSpacing: 11,
                      mainAxisExtent: dramaExtent,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (BuildContext context, int index) =>
                          const _SkeletonCard(),
                      childCount: dramaColumns * 2,
                    ),
                  ),
                )
              else if (resultAsync.hasError && dramas.isEmpty)
                SliverToBoxAdapter(
                  child: _LoadError(
                    message: '筛选结果加载失败，请检查网络后重试',
                    onRetry: () =>
                        ref.invalidate(filterResultProvider(selectionsKey)),
                  ),
                )
              else if (dramas.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 36),
                    child: EmptyState(
                      icon: Icons.movie_filter_outlined,
                      title: '该题材正在筹备中',
                      message: '换个题材看看，更多好剧持续上新',
                      actionLabel: '看全部',
                      onAction: () => setState(() {
                        _resetPaging();
                        _selected.clear();
                      }),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: horizontal),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: dramaColumns,
                      mainAxisSpacing: 18,
                      crossAxisSpacing: 11,
                      mainAxisExtent: dramaExtent,
                    ),
                    delegate: SliverChildBuilderDelegate((
                      BuildContext context,
                      int index,
                    ) {
                      final Drama drama = dramas[index];
                      return DramaCard(
                        drama: drama,
                        onTap: () => openDramaDetail(context, drama),
                      );
                    }, childCount: dramas.length),
                  ),
                ),
              if (hasMore)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(horizontal, 14, horizontal, 6),
                    child: Center(
                      child: AppPillButton(
                        label: _loadingMore ? '加载中…' : '加载更多',
                        onPressed: _loadingMore
                            ? null
                            : () => _loadMore(selectionsKey, firstPage),
                      ),
                    ),
                  ),
                ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 26)),
          ],
        ),
      ),
    );
  }

  /// 筛选面板：每组一行（组名 + 该组选项横滑 SoftChip），三态齐全。
  Widget _buildPanel(
    BuildContext context,
    AsyncValue<List<FilterGroupData>> panelAsync,
  ) {
    final AppColors colors = context.colors;
    return panelAsync.when(
      skipLoadingOnReload: true,
      data: (List<FilterGroupData> groups) {
        final List<FilterGroupData> rows = <FilterGroupData>[
          for (final FilterGroupData group in groups)
            if (group.options.isNotEmpty) group,
        ];
        // 收纳态只露第一组；已有选中项的组强制显示，避免「选了但看不见」。
        final List<FilterGroupData> visible =
            _filtersExpanded || rows.length <= 1
            ? rows
            : rows
                  .where(
                    (FilterGroupData group) =>
                        group == rows.first || _hasSelection(group),
                  )
                  .toList();
        return Column(
          children: <Widget>[
            for (final FilterGroupData group in visible)
              Builder(
                builder: (BuildContext context) {
                  final List<(String, String)> options = _optionsFor(group);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 9),
                    child: Row(
                      children: <Widget>[
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 44),
                          child: Text(
                            group.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              height: 1.2,
                              fontWeight: FontWeight.w600,
                              color: colors.textTertiary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: <Widget>[
                                for (int i = 0; i < options.length; i++)
                                  Padding(
                                    padding: EdgeInsets.only(
                                      right: i == options.length - 1 ? 0 : 8,
                                    ),
                                    child: SoftChip(
                                      label: options[i].$1,
                                      selected: _isSelected(group, options, i),
                                      onTap: () => _toggle(group, options, i),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            if (rows.length > 1)
              Align(
                alignment: Alignment.centerLeft,
                child: GestureDetector(
                  onTap: () =>
                      setState(() => _filtersExpanded = !_filtersExpanded),
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 6,
                      horizontal: 2,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          _filtersExpanded ? '收起筛选' : '展开全部筛选',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: colors.brand,
                          ),
                        ),
                        Icon(
                          _filtersExpanded
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          size: 16,
                          color: colors.brand,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
      loading: () => const _PanelSkeleton(),
      error: (Object error, StackTrace stackTrace) => _LoadError(
        message: '筛选面板加载失败，请检查网络后重试',
        onRetry: () => ref.invalidate(filterPanelProvider),
      ),
    );
  }
}

/// 筛选面板加载骨架：两行占位 chips，对齐真实面板的单行高度。
class _PanelSkeleton extends StatelessWidget {
  const _PanelSkeleton();

  @override
  Widget build(BuildContext context) {
    final AppColors colors = context.colors;

    Widget stub(double width) {
      return Container(
        height: 31,
        width: width,
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          borderRadius: BorderRadius.circular(10),
        ),
      );
    }

    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            stub(30),
            const SizedBox(width: 8),
            stub(56),
            const SizedBox(width: 8),
            stub(48),
            const SizedBox(width: 8),
            stub(62),
          ],
        ),
        const SizedBox(height: 9),
        Row(
          children: <Widget>[
            stub(30),
            const SizedBox(width: 8),
            stub(52),
            const SizedBox(width: 8),
            stub(58),
          ],
        ),
      ],
    );
  }
}

/// 剧集卡占位，与 DramaCard 的海报 + 两行文案结构一致。
class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard();

  @override
  Widget build(BuildContext context) {
    final AppColors colors = context.colors;
    final Color base = colors.surfaceMuted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: base,
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        const SizedBox(height: 9),
        Container(
          height: 12,
          width: 72,
          decoration: BoxDecoration(
            color: base,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(height: 5),
        Container(
          height: 9,
          width: 48,
          decoration: BoxDecoration(
            color: base,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      ],
    );
  }
}

/// 加载失败提示：点按整卡重试（ref.invalidate 由调用方注入）。
class _LoadError extends StatelessWidget {
  const _LoadError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 32),
      child: EmptyState(
        icon: Icons.cloud_off_rounded,
        title: '内容加载失败',
        message: message,
        actionLabel: '点按重试',
        onAction: onRetry,
      ),
    );
  }
}
