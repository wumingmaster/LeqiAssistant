package party.xiaoyu.glasses.wakeprobe;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInstaller;
import android.widget.Toast;

public final class UpdateInstallReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent result) {
        int status = result.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE);
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            Intent confirm = result.getParcelableExtra(Intent.EXTRA_INTENT);
            if (confirm != null) try { context.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); return; } catch (Exception ignored) { }
            Toast.makeText(context, "请返回小米同学并确认安装", Toast.LENGTH_LONG).show();
        } else if (status != PackageInstaller.STATUS_SUCCESS) {
            Toast.makeText(context, "安装未完成，旧版仍保留", Toast.LENGTH_LONG).show();
        }
    }
}
