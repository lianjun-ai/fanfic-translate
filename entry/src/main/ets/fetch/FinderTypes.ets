import { common } from '@kit.AbilityKit';
import { ProviderConfig } from '../common/Settings';
import { FicMeta } from './FicHub';
import { PendingItem } from './PendingStore';

/**
 * 找文 Agent 的公共类型。
 *
 * 抽出来单独放，是因为 Agent 主循环（FinderAgent）和工具实现（FinderTools）
 * 互相需要对方的类型，塞在同一个文件里不好读、跨文件又会形成循环依赖。
 */

/**
 * 一个回合最多几轮模型往返（=「步数」）。
 *
 * 注意这是**模型调用次数**，不是工具调用次数：一轮里模型可以一次发出
 * 多个互不依赖的工具调用。所以省步数的正解是让模型并行发工具，而不是
 * 简单把这个数字调大 —— 调大只会让单次对话更慢更贵。
 */
export const MAX_ROUNDS: number = 12;

/** 剩余步数少于这个值时，工具返回里会带上「准备收尾」的提示 */
export const ROUNDS_WARN_AT: number = 3;

/** 页面订阅的过程事件：思考流、动作、命中、下载、状态 */
export interface AgentHooks {
  /** 一轮模型输出开始：新建一个流式气泡并把 id 返回给这里 */
  onRoundStart: () => string;
  /** 该轮的累计文本（边生成边回调），上层直接覆盖显示 */
  onThinkDelta: (id: string, text: string) => void;
  /** 该轮结束：isFinal=true 表示这是最终回复（不是中间思考），气泡该换样式 */
  onRoundEnd: (id: string, isFinal: boolean) => void;
  /** 一次工具调用或中间结论 */
  onAction: (text: string) => void;
  /** 拿到了真实作品元信息（UI 插入卡片） */
  onHit: (meta: FicMeta) => void;
  /** 下载完成落入待入库区 */
  onDownloaded: (item: PendingItem) => void;
  /** 顶部状态行 */
  onStatus: (text: string) => void;
}

/** 工具执行需要的运行时上下文 */
export interface FinderCtx {
  cfg: ProviderConfig;
  ui: common.UIAbilityContext;
  hooks: AgentHooks;
}

/** 一个回合跑完的产出（消息历史已由 chatTurn 直接写入传入的 history） */
export interface FinderResult {
  hits: FicMeta[];
  downloaded: PendingItem[];
  finalText: string;
}

/**
 * 一次回合的运行闸门：用户点「停止」时用它同时做两件事 ——
 * 让主循环在下一个检查点退出，并立刻打断在途的网络请求。
 *
 * 为什么不只是设个布尔：模型流式生成时 await 卡在请求上，
 * 光设标志位它不会自己醒过来，必须把连接打掉。
 */
export class RunControl {
  /** 已请求停止 */
  cancelled: boolean = false;
  /** 由 FinderAgent 绑定的中断器：立即打断进行中的模型请求 */
  private aborter: (() => void) | null = null;

  /** Agent 每回合开始时绑定；若这时用户已经点过停止，立刻生效 */
  bind(aborter: () => void): void {
    this.aborter = aborter;
    if (this.cancelled) {
      aborter();
    }
  }

  unbind(): void {
    this.aborter = null;
  }

  cancel(): void {
    if (this.cancelled) {
      return;
    }
    this.cancelled = true;
    const fn = this.aborter;
    if (fn !== null) {
      fn();
    }
  }
}
