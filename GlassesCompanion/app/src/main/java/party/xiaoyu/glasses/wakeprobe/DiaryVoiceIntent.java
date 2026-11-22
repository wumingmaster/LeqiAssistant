package party.xiaoyu.glasses.wakeprobe;

/** Explicit command routing; ordinary Xiaoai requests are left untouched. */
final class DiaryVoiceIntent {
    enum Action { NONE, ENTER, PHOTO, DICTATE, EXIT }

    static Action parse(String recognition, boolean inDiary) {
        if (recognition == null) return Action.NONE;
        String text = recognition.replaceAll("[\\s，。！？、,.!?]", "");
        if (!inDiary) {
            return text.equals("记日记") || text.equals("我要记日记") || text.equals("帮我记日记")
                    ? Action.ENTER : Action.NONE;
        }
        if (text.equals("拍照") || text.equals("拍一张照片") || text.equals("拍张照片")) return Action.PHOTO;
        if (text.equals("说日记") || text.equals("语音日记") || text.equals("记录语音")) return Action.DICTATE;
        if (text.equals("退出") || text.equals("退出日记") || text.equals("完成")) return Action.EXIT;
        return Action.NONE;
    }
    private DiaryVoiceIntent() { }
}
