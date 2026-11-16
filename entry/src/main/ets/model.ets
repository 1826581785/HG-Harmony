/** 数据模型：从 API JSON（Record）映射为强类型类。字段对应旧工程 src/types.ts。 */

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

  static from(o: Record<string, Object>): VideoCard {
    const c = new VideoCard();
    c.id = (o['id'] as number) ?? 0;
    c.title = (o['title'] as string) ?? '';
    c.cover = (o['cover'] as string) ?? '';
    c.description = (o['description'] as string) ?? '';
    c.score = (o['score'] as number) ?? 0;
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
