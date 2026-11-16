/** 数据模型：从 API JSON（Record）映射为强类型类。字段对应旧工程 src/types.ts。 */

/** push('feedview') 的导航参数 */
export interface FeedNavParam {
  ids: number[];
  title: string;
  /** 起始播放下标 */
  index: number;
}

/** push('channel') 的导航参数 */
export interface ChannelNavParam {
  cate: string;
  name: string;
}

/** push('favlist') 的导航参数 */
export interface FavListNavParam {
  kind: string;
  title: string;
}

export class VideoCard {
  id: number = 0;
  title: string = '';
  cover: string = '';
  description: string = '';
  authorName: string = '';
  score: number = 0;
  episodeCount: number = 0;
  totalEpisodes: number = 0;
  likeCount: number = 0;
  commentCount: number = 0;
  collectCount: number = 0;
  isFinished: boolean = false;
  tags: string[] = [];
  hot: number = 0;

  static from(o: Record<string, Object>): VideoCard {
    const c = new VideoCard();
    c.id = (o['id'] as number) ?? 0;
    c.title = (o['title'] as string) ?? '';
    c.cover = (o['cover'] as string) ?? '';
    c.description = (o['description'] as string) ?? '';
    c.score = (o['score'] as number) ?? 0;
    c.hot = (o['hot'] as number) ?? 0;
    c.episodeCount = (o['episode_count'] as number) ?? 0;
    c.totalEpisodes = (o['total_episodes'] as number) ?? 0;
    c.likeCount = (o['like_count'] as number) ?? 0;
    c.commentCount = (o['comment_count'] as number) ?? 0;
    c.collectCount = (o['collect_count'] as number) ?? 0;
    c.isFinished = (o['is_finished'] as boolean) ?? false;
    const tags = o['tags'] as Array<string>;
    c.tags = tags ?? [];
    const author = o['author'] as Record<string, Object>;
    if (author) {
      c.authorName = (author['name'] as string) ?? '';
    }
    return c;
  }
}

export class VideoDetail {
  id: number = 0;
  title: string = '';
  cover: string = '';
  description: string = '';
  score: number = 0;
  episodeCount: number = 0;
  totalEpisodes: number = 0;
  authorName: string = '';
  authorId: number = 0;
  likeCount: number = 0;
  commentCount: number = 0;
  collectCount: number = 0;
  isFinished: boolean = false;
  tags: string[] = [];
  hot: number = 0;
  /** 集号列表（升序） */
  episodes: number[] = [];

  static from(o: Record<string, Object>): VideoDetail {
    const d = new VideoDetail();
    d.id = (o['id'] as number) ?? 0;
    d.title = (o['title'] as string) ?? '';
    d.cover = (o['cover'] as string) ?? '';
    d.description = (o['description'] as string) ?? '';
    d.score = (o['score'] as number) ?? 0;
    d.episodeCount = (o['episode_count'] as number) ?? 0;
    d.totalEpisodes = (o['total_episodes'] as number) ?? 0;
    d.isFinished = (o['is_finished'] as boolean) ?? false;
    const tags = o['tags'] as Array<string>;
    d.tags = tags ?? [];
    const author = o['author'] as Record<string, Object>;
    if (author) {
      d.authorName = (author['name'] as string) ?? '';
      d.authorId = (author['id'] as number) ?? 0;
    }
    const counts = o['counts'] as Record<string, Object>;
    if (counts) {
      d.likeCount = (counts['like'] as number) ?? 0;
      d.commentCount = (counts['comment'] as number) ?? 0;
      d.collectCount = (counts['collect'] as number) ?? 0;
      d.hot = (counts['hot'] as number) ?? 0;
    }
    const eps = (o['episodes'] as Array<Record<string, Object>>) ?? [];
    for (const e of eps) {
      const epNum = (e['ep_num'] as number) ?? 0;
      if (epNum > 0) {
        d.episodes.push(epNum);
      }
    }
    d.episodes.sort((a: number, b: number) => a - b);
    return d;
  }
}

export class Comment {
  id: number = 0;
  userId: number = 0;
  nickname: string = '';
  avatar: string = '';
  text: string = '';
  time: string = '';
  likeCount: number = 0;
  replyCount: number = 0;
  isPinned: boolean = false;
  ipRegion: string = '';

  static from(o: Record<string, Object>): Comment {
    const c = new Comment();
    c.id = (o['id'] as number) ?? 0;
    c.userId = (o['user_id'] as number) ?? 0;
    c.nickname = (o['nickname'] as string) ?? '';
    c.avatar = (o['avatar'] as string) ?? '';
    c.text = (o['text'] as string) ?? '';
    c.time = (o['time'] as string) ?? ((o['created_at'] as string) ?? '');
    c.likeCount = (o['like_count'] as number) ?? 0;
    c.replyCount = (o['reply_count'] as number) ?? 0;
    c.isPinned = (o['is_pinned'] as boolean) ?? false;
    c.ipRegion = (o['ip_region'] as string) ?? '';
    return c;
  }
}

export class CommentPageData {
  items: Comment[] = [];
  pages: number = 1;

  static from(o: Record<string, Object>): CommentPageData {
    const p = new CommentPageData();
    const items = (o['items'] as Array<Record<string, Object>>) ?? [];
    for (const it of items) {
      p.items.push(Comment.from(it));
    }
    const pg = o['pagination'] as Record<string, Object>;
    if (pg) {
      p.pages = (pg['pages'] as number) ?? 1;
    }
    return p;
  }
}

export class Pagination {
  page: number = 1;
  pages: number = 1;
  size: number = 20;
  total: number = 0;

  static from(o: Record<string, Object> | undefined): Pagination {
    const p = new Pagination();
    if (!o) {
      return p;
    }
    p.page = (o['page'] as number) ?? 1;
    p.pages = (o['pages'] as number) ?? 1;
    p.size = (o['size'] as number) ?? 20;
    p.total = (o['total'] as number) ?? 0;
    return p;
  }
}

export class User {
  id: number = 0;
  username: string = '';
  nickname: string = '';
  sign: string = '';
  likeCount: number = 0;
  collectCount: number = 0;
  followingCount: number = 0;
  /** 服务端互动列表（me() 返回的 interactions），用于登录后恢复本地标记 */
  likeIds: number[] = [];
  favIds: number[] = [];
  followIds: number[] = [];

  static from(o: Record<string, Object>): User {
    const u = new User();
    u.id = (o['id'] as number) ?? 0;
    u.username = (o['username'] as string) ?? '';
    u.nickname = (o['nickname'] as string) ?? '';
    u.sign = (o['sign'] as string) ?? ((o['desc'] as string) ?? '');
    const counts = o['counts'] as Record<string, Object>;
    if (counts) {
      u.likeCount = (counts['like'] as number) ?? 0;
      u.collectCount = (counts['collect'] as number) ?? 0;
      u.followingCount = (counts['following'] as number) ?? 0;
    }
    const inter = o['interactions'] as Record<string, Object>;
    if (inter) {
      const likes = inter['like_video_ids'] as Array<number>;
      u.likeIds = likes ?? [];
      const favs = inter['favorite_video_ids'] as Array<number>;
      u.favIds = favs ?? [];
      const follows = inter['follow_user_ids'] as Array<number>;
      u.followIds = follows ?? [];
    }
    return u;
  }
}

export class RankItem {
  rank: number = 0;
  videoId: number = 0;
  title: string = '';
  cover: string = '';
  tags: string[] = [];
  score: number = 0;
  cateName: string = '';
  metricLabel: string = '';
  metricValue: number = 0;

  static from(o: Record<string, Object>): RankItem {
    const r = new RankItem();
    r.rank = (o['rank'] as number) ?? 0;
    r.videoId = (o['video_id'] as number) ?? 0;
    r.title = (o['title'] as string) ?? '';
    r.cover = (o['cover'] as string) ?? '';
    const tags = o['tags'] as Array<string>;
    r.tags = tags ?? [];
    r.score = (o['score'] as number) ?? 0;
    r.cateName = (o['cate_name'] as string) ?? '';
    r.metricLabel = (o['metric_label'] as string) ?? '';
    r.metricValue = (o['metric_value'] as number) ?? 0;
    return r;
  }
}

export class Post {
  id: number = 0;
  title: string = '';
  desc: string = '';
  content: string = '';
  cover: string = '';
  tags: string[] = [];
  hot: number = 0;
  videoUrl: string = '';
  videoId: number = 0;
  authorName: string = '';
  publishTime: string = '';

  static from(o: Record<string, Object>): Post {
    const p = new Post();
    p.id = (o['id'] as number) ?? 0;
    p.title = (o['title'] as string) ?? '';
    p.desc = (o['desc'] as string) ?? '';
    p.content = (o['content'] as string) ?? '';
    p.cover = (o['cover'] as string) ?? '';
    const tags = o['tags'] as Array<string>;
    p.tags = tags ?? [];
    p.hot = (o['hot'] as number) ?? 0;
    p.videoUrl = (o['video_url'] as string) ?? '';
    p.videoId = (o['video_id'] as number) ?? 0;
    p.publishTime = (o['publish_time'] as string) ?? ((o['created_at'] as string) ?? '');
    const author = o['author'] as Record<string, Object>;
    if (author) {
      p.authorName = (author['name'] as string) ?? '';
    }
    return p;
  }
}

/** 帖子详情：content 可能是 HTML 或纯文本 */
export class PostDetailData extends Post {
  contentIsHtml: boolean = false;

  static fromDetail(o: Record<string, Object>): PostDetailData {
    const p = PostDetailData.from(o) as PostDetailData;
    const c = p.content;
    p.contentIsHtml = /<(p|div|br|img|h[1-6]|ul|ol|li|blockquote|span|strong|em)[\s>]/i.test(c);
    return p;
  }
}
