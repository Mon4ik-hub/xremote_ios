import Foundation

/// HTML-фрагменты для тестов разбора (шаг «Core»).
enum Fixtures {
    static let animePage = """
    <!doctype html><html><head><title>тест</title></head><body>
    <h1 class="page__title">Тайная битва за престол <b>сильнейшего</b> принца-дуралея</h1>
    <div data-anime-player-loader-url-value="/player/3592"></div>
    </body></html>
    """

    static let episodesHtml = """
    <div data-episode-number="1" data-episode-page="0" data-episode-index="0" data-episode-type="0" data-episode="100001">1</div>
    <div data-episode-number="2" data-episode-page="0" data-episode-index="1" data-episode-type="0" data-episode="100002">2</div>
    <span data-episode-number="3" data-episode-page="1" data-episode-index="0" data-episode-type="0" data-episode="100003">3</span>
    """

    static let emptyHtml = "<div>серий нет</div>"

    static let providersHtml = """
    <button data-player="https://s3.cdnvideohub.com/public/cdn-iframe/123/Dream&#x20;Cast/1/1?scene=1" data-provider-title="CVH" data-translation-title="Dream Cast"></button>
    <button data-player="https://kodik.info/find-player?shikimori=1&amp;bad=false" data-provider-title="Kodik" data-translation-title="AniLiberty"></button>
    <button data-player="https://aniboom.one/embed/x" data-provider-title="AniBoom" data-translation-title="Dream Cast"></button>
    """
}
