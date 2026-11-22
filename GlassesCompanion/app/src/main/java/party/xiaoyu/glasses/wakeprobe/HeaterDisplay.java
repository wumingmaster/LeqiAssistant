package party.xiaoyu.glasses.wakeprobe;

final class HeaterDisplay {
    static String format(String state, String current, String target, String mode) {
        if (!"heat".equals(state)) return "";
        StringBuilder text = new StringBuilder("二楼暖气");
        if (!"--".equals(current)) text.append(" ").append(current).append("°");
        if (!"--".equals(target)) text.append(" → ").append(target).append("°");
        if (mode.startsWith("强暖")) text.append(" 强暖");
        else if (mode.startsWith("弱暖")) text.append(" 弱暖");
        return text.toString();
    }
}
