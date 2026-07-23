#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "$BASH_SOURCE")/.."; pwd)"
source "$PROJECT_ROOT/scripts/common.sh"

if [[ ${sparkle_key} == "" ]]
then
    echo "Error: No Sparkle key"
    exit 1
fi

download_url='https://github.com/qwertyyb/Fire/releases/latest/download/FireInstaller.zip'

str=$($PROJECT_ROOT/bin/sign_update -s "${sparkle_key}" "$EXPORT_INSTALLER_ZIP")

sign=$(echo $str | grep "edSignature=\"[^\"]*" -o | grep "\"[^\"]*" -o)
sign=${sign#\"}

length=$(echo $str | grep "length=\"[^\"]*" -o | grep "\"[^\"]*" -o)
length=${length#\"}

echo "${sign}";
echo "${length}"

if [[ $sign == "" ]]
then
    echo "Sign Failed: no sign"
    exit 1
fi


CFBundleVersion=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PROJECT_ROOT/Fire/Info.plist")

echo "${NEXT_VERSION}"
echo "${CFBundleVersion}"

cat>$EXPORT_PATH/appcast.xml<<EOF
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>${APP_NAME}</title>
        <item>
            <title>${NEXT_VERSION}</title>
            <pubDate>$(date -R)</pubDate>
            <sparkle:minimumSystemVersion>11.0</sparkle:minimumSystemVersion>
            <description><![CDATA[
                ${update_notes}
            ]]>
            </description>
            <enclosure url="${download_url}"
              sparkle:version="${CFBundleVersion}"
              sparkle:shortVersionString="${NEXT_VERSION}"
              length="${length}"
              sparkle:edSignature="${sign}"
              type="application/octet-stream"/>
        </item>
    </channel>
</rss>
EOF