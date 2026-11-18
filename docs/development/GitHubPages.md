# GitHub Pages 文件網站

網站使用 GitHub Pages 的 `main` 分支根目錄與 Jekyll Primer 版型，對照 simStock3 的實際 `main`／根目錄部署及 Primer 網站。保留 Primer 的單欄 Markdown 排版；精簡 layout 讓 HTML 的 `lang` 依頁面區分中文／英文。沒有獨立首頁正文；`jekyll-readme-index` 直接把中文 `README.md` 產生成首頁。更新 README 後，Pages 會重新建置。

`jekyll-relative-links` 把網站內 Markdown 文件連結轉成對應 HTML。程式、修補與建置材料不發佈為網站靜態附件，相關連結指向 GitHub 原檔；原始第三方許可文字保持不變。網站提供文件與 [App Store 下載連結](https://apps.apple.com/us/app/vista/id6835254123)；App 經 App Store 分發，網站不直接提供安裝包。

`docs` 本層只放使用者說明及聲明，提供中文和英文；開發文件放在 `docs/development`，不另翻譯。第三方完整原文放在 `docs/third-party-licenses`。根目錄 README 保持中文，頁面不依系統語言換成另一份介紹。

文件移動時應同時核對所有現行相對連結與 App 內線上入口。GitHub 的舊 `blob/main/docs/...` 外部網址不會因 Git rename 自動轉址；既有歷史提交仍保留原檔。新的現行連結應使用移動後路徑。
