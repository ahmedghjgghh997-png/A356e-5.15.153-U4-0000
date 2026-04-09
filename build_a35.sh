#!/bin/bash
# ============================================================
# سكريبت بناء نواة Samsung Galaxy A35 (Exynos 1380) مع KernelSU
# يعطل جميع حمايات سامسونج، يدعم AnyKernel3 أو boot.img مباشر
# يتعامل مع ملفات Google Drive (سواء zip أو tar.gz) بأمان
# ============================================================
set -e

# الألوان
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ========== دالة المساعدة ==========
usage() {
    cat << EOF
الاستخدام: $0 --source-url <رابط السورس> [خيارات]

خيارات إلزامية:
  --source-url URL     رابط تحميل سورس الكيرنال (GitHub, Google Drive, أو رابط مباشر)

خيارات اختيارية:
  --boot-url URL       رابط مباشر لـ boot.img الأصلي (إذا تركته فارغاً، سيُصنع AnyKernel3.zip)
  --permissive METHOD  gabriel | thomas | none   (جعل SELinux permissive، الافتراضي: none)
  --zram-lz4           تفعيل ضغط lz4 بدلاً من lzo لـ zram (تحسين الأداء)
  --image-gz           بناء Image.gz بدلاً من Image (مضغوط، موصى به)
  --disable-module-sig تعطيل توقيعات الوحدات (لتفادي مشاكل الواي فاي)
  --fix-el-flag        إصلاح خطأ '-EL' في Makefile (إذا واجهته)
  --fix-strncpy        تطبيق إصلاح strncpy (إذا لزم)
  --push-github URL    رفع السورس المعدل إلى مستودع GitHub بعد البناء
  --help               عرض هذه المساعدة

أمثلة:
  # بناء أساسي (موصى به)
  $0 --source-url https://github.com/raspiduino/sm-a356e-kernel.git --permissive gabriel --zram-lz4 --image-gz

  # بناء مع boot.img محدد
  $0 --source-url "https://drive.google.com/..." --boot-url "https://example.com/boot.img" --permissive thomas
EOF
    exit 1
}

# ========== قراءة المعاملات ==========
SOURCE_URL=""
BOOT_URL=""
PERMISSIVE="none"
ZRAM_LZ4=false
IMAGE_GZ=false
DISABLE_MODULE_SIG=false
FIX_EL_FLAG=false
FIX_STRNCPY=false
PUSH_GITHUB_URL=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --source-url) SOURCE_URL="$2"; shift 2 ;;
        --boot-url)   BOOT_URL="$2"; shift 2 ;;
        --permissive) PERMISSIVE="$2"; shift 2 ;;
        --zram-lz4)   ZRAM_LZ4=true; shift ;;
        --image-gz)   IMAGE_GZ=true; shift ;;
        --disable-module-sig) DISABLE_MODULE_SIG=true; shift ;;
        --fix-el-flag) FIX_EL_FLAG=true; shift ;;
        --fix-strncpy) FIX_STRNCPY=true; shift ;;
        --push-github) PUSH_GITHUB_URL="$2"; shift 2 ;;
        --help) usage ;;
        *) echo -e "${RED}خطأ: معامل غير معروف $1${NC}"; usage ;;
    esac
done

[ -z "$SOURCE_URL" ] && { echo -e "${RED}خطأ: يجب تحديد --source-url${NC}"; usage; }

# ========== الخطوة 1-5: إعداد نظام لينكس وتبعيات ==========
echo -e "${GREEN}[الخطوات 1-5] تثبيت التبعيات الأساسية...${NC}"
sudo apt update
sudo apt upgrade -y
sudo apt install -y git make gcc
sudo apt install -y python-is-python3 build-essential openssl pip
pip install virtualenv
sudo apt install -y python3-virtualenv
sudo add-apt-repository -y ppa:deadsnakes/ppa
sudo apt update
sudo apt install -y python2.7
sudo apt install -y libssl-dev
sudo apt-get install -y libtinfo5
sudo apt install -y bc bison flex cpio kmod wget curl unzip xz-utils device-tree-compiler
pip install gdown

# إعداد repo (أداة Google)
mkdir -p ~/.bin
export PATH="$HOME/.bin:$PATH"
curl https://storage.googleapis.com/git-repo-downloads/repo > ~/.bin/repo
chmod a+rx ~/.bin/repo

# ========== الخطوة 6: تنزيل السورس وفك الضغط بأمان ==========
echo -e "${GREEN}[الخطوة 6] تنزيل السورس من: $SOURCE_URL${NC}"

# حذف أي مجلد kernel_source قديم لتجنب التراكم
rm -rf kernel_source
mkdir -p kernel_source
cd kernel_source

# دالة لتحويل رابط Google Drive إلى رابط مباشر
get_gdrive_direct() {
    local url="$1"
    local file_id=$(echo "$url" | grep -oP '(?<=/d/)[a-zA-Z0-9_-]+' | head -1)
    [ -z "$file_id" ] && file_id=$(echo "$url" | grep -oP 'id=[a-zA-Z0-9_-]+' | cut -d= -f2)
    echo "https://drive.google.com/uc?export=download&id=$file_id"
}

# تنزيل الملف
DOWNLOAD_SUCCESS=false
if [[ "$SOURCE_URL" == *drive.google.com* ]]; then
    DIRECT_URL=$(get_gdrive_direct "$SOURCE_URL")
    echo "تحميل من Google Drive..."
    gdown --fuzzy "$DIRECT_URL" -O source.file && DOWNLOAD_SUCCESS=true
elif [[ "$SOURCE_URL" == *.git ]]; then
    echo "استنساخ من git..."
    git clone --depth=1 "$SOURCE_URL" .
    DOWNLOAD_SUCCESS=true
else
    echo "تحميل من رابط مباشر..."
    wget -O source.file "$SOURCE_URL" && DOWNLOAD_SUCCESS=true
fi

if [ "$DOWNLOAD_SUCCESS" = false ]; then
    echo -e "${RED}خطأ: فشل تحميل السورس${NC}"
    exit 1
fi

# فك الضغط إذا كان الملف ليس مستودع git
if [[ "$SOURCE_URL" != *.git ]]; then
    FILE_TYPE=$(file -b --mime-type source.file)
    echo "نوع الملف: $FILE_TYPE"
    
    case "$FILE_TYPE" in
        application/zip)
            echo "فك ضغط zip..."
            unzip -q source.file
            ;;
        application/x-tar|application/x-gzip|application/gzip)
            echo "فك ضغط tar.gz..."
            tar -xzf source.file
            ;;
        application/x-xz)
            echo "فك ضغط tar.xz..."
            tar -xJf source.file
            ;;
        application/x-bzip2)
            echo "فك ضغط tar.bz2..."
            tar -xjf source.file
            ;;
        *)
            echo -e "${YELLOW}نوع ملف غير معروف، محاولة tar كحل أخير...${NC}"
            if tar -xf source.file 2>/dev/null; then
                echo "تم فك الضغط باستخدام tar"
            else
                echo -e "${RED}خطأ: لا يمكن فك ضغط الملف. تأكد من صيغته.${NC}"
                exit 1
            fi
            ;;
    esac
    rm source.file
    
    # إذا كان السورس داخل مجلد فرعي واحد، ننقله للأعلى
    if [ $(ls -1 | wc -l) -eq 1 ] && [ -d $(ls -1) ]; then
        SUBDIR=$(ls -1)
        echo "نقل محتويات المجلد $SUBDIR إلى الأعلى..."
        mv $SUBDIR/* ./
        rmdir $SUBDIR
    fi
fi

# التأكد من وجود Makefile
if [ ! -f "Makefile" ]; then
    echo -e "${RED}خطأ: Makefile غير موجود في السورس. تأكد من صحة الرابط.${NC}"
    exit 1
fi

echo -e "${GREEN}تم تحضير السورس بنجاح في $(pwd)${NC}"
cd ..

# ========== الخطوة 7: إضافة toolchains ==========
echo -e "${GREEN}[الخطوة 7] تحميل سلاسل الأدوات (clang-r383902)...${NC}"
mkdir -p ~/toolchains
cd ~/toolchains
if [ ! -d "clang-r383902" ]; then
    git clone https://github.com/physwizz/clang-r383902.git
fi
cd clang-r383902
export CLANG_PATH="$PWD/clang/host/linux-x86/clang-r383902"
export GCC_PATH="$PWD/gcc/linux-x86/aarch64/aarch64-linux-android-4.9"
export PATH="$CLANG_PATH/bin:$GCC_PATH/bin:$PATH"
cd -

# ========== الخطوة 8: إعداد متغيرات البناء ==========
echo -e "${GREEN}[الخطوة 8] إعداد متغيرات البناء...${NC}"
export ARCH=arm64
export CROSS_COMPILE="aarch64-linux-android-"
export CLANG_TRIPLE="aarch64-linux-gnu-"
export CC=clang
export LD=ld.lld
export LLVM=1
export LLVM_IAS=1
export TARGET_SOC=s5e8835
export PLATFORM_VERSION=15
export ANDROID_MAJOR_VERSION=v
export LTO=none
export KCFLAGS="-Wno-error -Wno-typedef-redefinition -fno-stack-protector"
export KCPPFLAGS="-Wno-error"

# التأكد من وجود مجلد kernel_source قبل الدخول
if [ ! -d "kernel_source" ]; then
    echo -e "${RED}خطأ: مجلد kernel_source غير موجود!${NC}"
    exit 1
fi
cd kernel_source

# ========== الخطوة 9: إضافة KernelSU ==========
echo -e "${GREEN}[الخطوة 9] دمج KernelSU...${NC}"
curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -

# ========== الخطوات 10-16: تعطيل الحماية ==========
echo -e "${GREEN}[الخطوات 10-16] تعطيل جميع حمايات سامسونج...${NC}"
cat > custom.config << 'EOF'
# تعطيل RKP و UH
CONFIG_UH=n CONFIG_UH_RKP=n CONFIG_UH_LKMAUTH=n CONFIG_UH_LKM_BLOCK=n
CONFIG_RKP_CFP_JOPP=n CONFIG_RKP_CFP=n CONFIG_RKP_KDP=n CONFIG_RKP_NS_PROT=n CONFIG_RKP_DMAP_PROT=n
# Defex, Proca, FIVE
CONFIG_SECURITY_DEFEX=n CONFIG_PROCA=n CONFIG_FIVE=n
# TIMA و Knox
CONFIG_TIMA=n CONFIG_TIMA_LKMAUTH=n CONFIG_TIMA_LKM_BLOCK=n CONFIG_TIMA_LKMAUTH_CODE_PROT=n CONFIG_TIMA_LOG=n
CONFIG_KNOX_KAP=n CONFIG_KNOX_NCM=n
# DM-Verity و Integrity
CONFIG_DM_VERITY=n
CONFIG_INTEGRITY=n CONFIG_INTEGRITY_SIGNATURE=n CONFIG_INTEGRITY_ASYMMETRIC_KEYS=n CONFIG_INTEGRITY_TRUSTED_KEYRING=n CONFIG_INTEGRITY_AUDIT=n
# تقييد root
CONFIG_SEC_RESTRICT_ROOTING=n CONFIG_SEC_RESTRICT_SETUID=n CONFIG_SEC_RESTRICT_FORK=n CONFIG_SEC_RESTRICT_ROOTING_LOG=n CONFIG_SECURITY_DSMS=n
# Stack Protector
CONFIG_CC_STACKPROTECTOR_STRONG=n
# LTO و BTF
CONFIG_LTO_CLANG=n CONFIG_LTO_CLANG_THIN=n CONFIG_LTO_CLANG_FULL=n CONFIG_LTO_NONE=y
CONFIG_DEBUG_INFO_BTF=n
# Module signatures
CONFIG_MODULE_SIG=n CONFIG_MODULE_SIG_FORCE=n CONFIG_MODULE_SIG_ALL=n CONFIG_MODULE_SIG_SHA512=n
# Force module load
CONFIG_MODULE_FORCE_LOAD=y CONFIG_MODULE_UNLOAD=y CONFIG_MODULE_FORCE_UNLOAD=y
# ضغط الكيرنال
CONFIG_KERNEL_GZIP=y CONFIG_LOCALVERSION_AUTO=n CONFIG_LOCALVERSION="-KernelSU"
# Governors
CONFIG_CPU_FREQ_GOV_PERFORMANCE=y CONFIG_CPU_FREQ_GOV_POWERSAVE=y CONFIG_CPU_FREQ_GOV_USERSPACE=y CONFIG_CPU_FREQ_GOV_ONDEMAND=y CONFIG_CPU_FREQ_GOV_INTERACTIVE=y CONFIG_CPU_FREQ_GOV_CONSERVATIVE=y
# ZRAM
CONFIG_ZRAM=y CONFIG_ZRAM_WRITEBACK=y CONFIG_ZRAM_MEMORY_TRACKING=y CONFIG_CRYPTO_LZ4=y
EOF

# ========== الخطوة 17: Permissive SELinux ==========
if [[ "$PERMISSIVE" == "gabriel" ]]; then
    echo -e "${GREEN}[الخطوة 17] تطبيق permissive SELinux (طريقة Gabriel)...${NC}"
    echo "CONFIG_SECURITY_SELINUX_DEVELOP=y" >> custom.config
    echo "CONFIG_SECURITY_SELINUX_ALWAYS_ENFORCE=n" >> custom.config
    echo "CONFIG_SECURITY_SELINUX_ALWAYS_PERMISSIVE=y" >> custom.config
elif [[ "$PERMISSIVE" == "thomas" ]]; then
    echo -e "${GREEN}[الخطوة 17] تطبيق permissive SELinux (طريقة Thomas)...${NC}"
    echo "CONFIG_CMDLINE=\"androidboot.selinux=permissive\"" >> custom.config
    echo "CONFIG_CMDLINE_EXTEND=y" >> custom.config
    echo "CONFIG_SECURITY_SELINUX_DEVELOP=y" >> custom.config
    echo "CONFIG_SECURITY_SELINUX_ALWAYS_ENFORCE=n" >> custom.config
    echo "CONFIG_SECURITY_SELINUX_ALWAYS_PERMISSIVE=y" >> custom.config
fi

# ========== الخطوة 18: ZRAM lz4 ==========
if [ "$ZRAM_LZ4" = true ]; then
    echo -e "${GREEN}[الخطوة 18] تغيير ضغط zram إلى lz4...${NC}"
    if [ -f "drivers/block/zram/zram_drv.c" ]; then
        sed -i 's/"lzo"/"lz4"/g' drivers/block/zram/zram_drv.c
    fi
fi

# ========== الخطوة 19: Module signatures ==========
if [ "$DISABLE_MODULE_SIG" = true ]; then
    echo -e "${GREEN}[الخطوة 19] تعطيل توقيعات الوحدات...${NC}"
    scripts/config --file .config -d CONFIG_MODULE_SIG
    scripts/config --file .config -d CONFIG_MODULE_SIG_FORCE
    if [ -f kernel/modules.c ]; then
        sed -i 's/return -ENOEXEC;/\/\/return -ENOEXEC;/' kernel/modules.c
    fi
fi

# ========== الخطوة 20: إصلاح -EL ==========
if [ "$FIX_EL_FLAG" = true ]; then
    echo -e "${GREEN}[الخطوة 20] إصلاح خطأ '-EL'...${NC}"
    if grep -q "GCC_TOOLCHAIN_DIR := \$(dir \$(shell which \$(CROSS_COMPILE)elfedit))" Makefile; then
        sed -i '/GCC_TOOLCHAIN_DIR := \$(dir \$(shell which \$(CROSS_COMPILE)elfedit))/d' Makefile
    fi
    if grep -q "CLANG_FLAGS += --prefix=\$(GCC_TOOLCHAIN_DIR)" Makefile; then
        sed -i 's/CLANG_FLAGS += --prefix=\$(GCC_TOOLCHAIN_DIR)/CLANG_FLAGS += --prefix=\$(GCC_TOOLCHAIN_DIR)\$(notdir \$(CROSS_COMPILE))/' Makefile
    fi
fi

# ========== الخطوة 21: إصلاح strncpy ==========
if [ "$FIX_STRNCPY" = true ]; then
    echo -e "${GREEN}[الخطوة 21] إصلاح strncpy...${NC}"
    scripts/config --file .config -d CONFIG_SECURITY_DEFEX
    git remote add a226 https://github.com/physwizz/a226-R.git
    git fetch a226
    git config merge.renameLimit 999999
    git cherry-pick 3b1bf239a3f17873cb91537cfdaa03173d396b33 || true
fi

# ========== الخطوة 22: تجهيز defconfig ==========
echo -e "${GREEN}[الخطوة 22] تجهيز defconfig...${NC}"
DEFCONFIG="s5e8835-a35xjvxx_defconfig"
make $DEFCONFIG
scripts/kconfig/merge_config.sh .config custom.config
scripts/config --file .config -d CONFIG_LTO_CLANG -d CONFIG_LTO_CLANG_THIN -d CONFIG_LTO_CLANG_FULL -e CONFIG_LTO_NONE
scripts/config --file .config -d CONFIG_DEBUG_INFO_BTF -d CONFIG_MODULE_SIG -d CONFIG_MODULE_SIG_FORCE
scripts/config --file .config --set-str CONFIG_LOCALVERSION "-KernelSU"

# ========== الخطوة 23: بناء الكيرنال ==========
echo -e "${GREEN}[الخطوة 23] بناء الكيرنال (قد يستغرق وقتاً)...${NC}"
if [ "$IMAGE_GZ" = true ]; then
    make -j$(nproc) Image.gz
    IMAGE_FILE="Image.gz"
else
    make -j$(nproc) Image
    IMAGE_FILE="Image"
fi
[ ! -f "arch/arm64/boot/$IMAGE_FILE" ] && { echo -e "${RED}فشل البناء${NC}"; exit 1; }
cp "arch/arm64/boot/$IMAGE_FILE" $HOME/Image
cd ..

# ========== الخطوة 24: تجهيز magiskboot و AnyKernel3 ==========
echo -e "${GREEN}[الخطوة 24] تجهيز ملف الفلاش...${NC}"
mkdir -p build_output
cp $HOME/Image build_output/

curl -L -o magisk.apk "https://github.com/topjohnwu/Magisk/releases/download/v28.1/Magisk-v28.1.apk"
unzip -j magisk.apk 'lib/x86_64/libmagiskboot.so' -d .
mv libmagiskboot.so magiskboot
chmod +x magiskboot
sudo cp magiskboot /usr/local/bin/
rm -f magisk.apk

if [ -n "$BOOT_URL" ]; then
    echo "تحميل boot.img من $BOOT_URL ..."
    if [[ "$BOOT_URL" == *drive.google.com* ]]; then
        DIRECT_URL=$(get_gdrive_direct "$BOOT_URL")
        gdown --fuzzy "$DIRECT_URL" -O boot.img
    else
        wget -O boot.img "$BOOT_URL"
    fi
    magiskboot unpack boot.img
    rm -f kernel
    cp $HOME/Image kernel
    magiskboot repack boot.img
    mv new-boot.img build_output/boot-ksu.img
    tar -cf build_output/boot-ksu.tar build_output/boot-ksu.img
    echo -e "${GREEN}تم إنشاء boot-ksu.img و boot-ksu.tar في build_output/${NC}"
else
    echo "إنشاء AnyKernel3.zip ..."
    git clone --depth=1 https://github.com/osm0sis/AnyKernel3.git
    cp $HOME/Image AnyKernel3/Image
    cd AnyKernel3
    zip -r9 ../build_output/AnyKernel3-$(date +%Y%m%d-%H%M%S).zip . -x ".git*" "README.md" "*.zip"
    cd ..
    echo -e "${GREEN}تم إنشاء AnyKernel3.zip في build_output/${NC}"
fi

# ========== الخطوة 25-33: رفع السورس إلى GitHub (اختياري) ==========
if [ -n "$PUSH_GITHUB_URL" ]; then
    echo -e "${GREEN}[الخطوات 25-33] رفع السورس المعدل إلى $PUSH_GITHUB_URL ...${NC}"
    cd kernel_source
    git init
    git add .
    git commit -m "Kernel source with KernelSU and security disabled"
    git remote add origin "$PUSH_GITHUB_URL"
    git branch -M main
    git push -u origin main -f
    cd ..
fi

echo -e "${GREEN}✅ اكتمل! المخرجات موجودة في مجلد build_output/${NC}"
