import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { dataSharePredicates } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { image } from '@kit.ImageKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'PhotoPicker';
/** 照片落地到应用沙箱 filesDir 下的这个子目录 */
const PHOTO_DIR: string = 'lingxing_photos';

/**
 * 把应用沙箱裸路径整理成 Image / createImageSource 都能稳定识别的 file:// URI。
 * 直接传 /data/storage/... 这种裸路径在很多机型上渲染不出来（白屏），套上 file:// 最稳。
 */
export function toFileUri(path: string): string {
  if (path.length === 0) {
    return path;
  }
  if (path.startsWith('file://')) {
    return path;
  }
  return 'file://' + path;
}

/**
 * 从相册选一张图，复制到应用沙箱，返回可长期稳定读取的沙箱绝对路径。
 * 用户取消选择时返回空串。
 *
 * 为什么必须复制：相册 picker 返回的 uri 是受限的，跨进程读取的临时授权会失效，
 * 直接把那个 uri 存进记录，下次打开多半读不出来。复制到 filesDir 之后，
 * 这是应用自己的地盘，能稳定加载，应用备份也带得走。
 *
 * 为什么用 PhotoAccessHelper 的 asset.open 而不是 fileIo.openSync(uri)：
 * 媒体库 uri 直接用 fs.open 打开，部分机型读不到真实字节（得到 0 字节文件 → 白屏）。
 * 走资产 fd 复制兼容性最好，复制完再 stat 校验体积，确保真的写进去了。
 */
export async function pickPhoto(context: common.Context): Promise<string> {
  let srcFd: number = 0;
  let destFd: number = 0;
  try {
    const ph: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
    const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
    const result: photoAccessHelper.PhotoSelectResult = await picker.select({
      MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
      maxSelectNumber: 1
    });
    if (result.photoUris.length === 0) {
      return '';
    }
    const srcUri: string = result.photoUris[0];

    const dir: string = context.filesDir + '/' + PHOTO_DIR;
    try {
      fileIo.mkdirSync(dir);
    } catch (e) {
      // 目录已存在：忽略
    }
    const lower: string = srcUri.toLowerCase();
    const ext: string = lower.endsWith('.png') ? '.png' : '.jpg';
    const dest: string = dir + '/' + Date.now().toString() + ext;

    // 通过媒体库资产拿到 fd 再复制，对相册 uri 兼容性最好
    const predicates: dataSharePredicates.DataSharePredicates = new dataSharePredicates.DataSharePredicates();
    predicates.equalTo(photoAccessHelper.PhotoKeys.URI, srcUri);
    const fetchOptions: photoAccessHelper.FetchOptions = {
      fetchColumns: [photoAccessHelper.PhotoKeys.URI],
      predicates: predicates
    };
    const fetchResult: photoAccessHelper.FetchResult<photoAccessHelper.PhotoAsset> =
      await ph.getAssets(fetchOptions);
    let copied: boolean = false;
    let asset: photoAccessHelper.PhotoAsset | null = null;
    try {
      if (fetchResult.getCount() === 0) {
        hilog.error(DOMAIN, TAG, 'asset not found for uri');
        return '';
      }
      asset = await fetchResult.getFirstObject();
      // API 26 起 PhotoAsset.open() 已移除，改用 getReadOnlyFd() 拿只读 fd
      srcFd = await asset.getReadOnlyFd();
      destFd = fileIo.openSync(dest, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE).fd;
      fileIo.copyFileSync(srcFd, destFd);
      copied = true;
    } finally {
      if (asset !== null && srcFd !== 0) {
        try { await asset.close(srcFd); } catch (e) {}
        srcFd = 0;
      }
      if (srcFd !== 0) {
        try { fileIo.closeSync(srcFd); } catch (e) {}
        srcFd = 0;
      }
      if (destFd !== 0) {
        try { fileIo.closeSync(destFd); } catch (e) {}
        destFd = 0;
      }
      try { fetchResult.close(); } catch (e) {}
    }
    if (!copied) {
      return '';
    }

    // 校验真的写进去了：0 字节多半是媒体库读取失败，这种图显示出来也是白的
    const stat: fileIo.Stat = fileIo.statSync(dest);
    if (stat === undefined || stat.size <= 0) {
      hilog.error(DOMAIN, TAG, 'copied file is empty, drop it');
      try { fileIo.unlinkSync(dest); } catch (e) {}
      return '';
    }
    return dest;
  } catch (err) {
    hilog.error(DOMAIN, TAG, 'pick failed: %{public}s', JSON.stringify(err));
    return '';
  } finally {
    if (srcFd !== 0) {
      try { fileIo.closeSync(srcFd); } catch (e) {}
    }
    if (destFd !== 0) {
      try { fileIo.closeSync(destFd); } catch (e) {}
    }
  }
}

/**
 * 把沙箱里的照片解码成 PixelMap，交给 Image() 渲染。
 * 走 PixelMap 能彻底绕开「Image 直接加载沙箱路径」的版本兼容问题，
 * 顺带验证文件是否真的能解出来（解不出返回 null，调用方再退回 file:// 路径兜底）。
 */
export async function loadPhotoPixelMap(path: string): Promise<image.PixelMap | null> {
  if (path.length === 0) {
    return null;
  }
  try {
    const src: image.ImageSource = image.createImageSource(toFileUri(path));
    const pm: image.PixelMap = await src.createPixelMap();
    return pm;
  } catch (err) {
    hilog.error(DOMAIN, TAG, 'decode failed: %{public}s', JSON.stringify(err));
    return null;
  }
}

/** 删掉沙箱里的照片（删待办时连带清掉，避免越堆越多）。失败静默忽略。 */
export function removePhoto(path: string): void {
  if (path.length === 0) {
    return;
  }
  try {
    if (fileIo.accessSync(path)) {
      fileIo.unlinkSync(path);
    }
  } catch (err) {
    hilog.error(DOMAIN, TAG, 'remove failed: %{public}s', JSON.stringify(err));
  }
}
