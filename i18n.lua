--[[
Plugin-local translations. Source strings (msgids) are the Brazilian Portuguese texts
already in the code; English is the default language and is looked up in EN below.
Strings identical in both languages ("Email", "OK", "%1 posts"…) have no entry.

Usage: local _ = require("i18n"); _("Buscar") -> "Search" (or "Buscar" in pt_BR).
It's translated at call time, so switching language only needs the screen redrawn.
Anything evaluated at module load (e.g. a table of labels) must call _() when used.
--]]

local SETTING = "inkwell_language"

local EN = {
    -- relative time / dates (date order is a template: dd/mm/yyyy vs mm/dd/yyyy)
    ["agora"] = "now",
    ["há %1 min"] = "%1 min ago",
    ["há %1 h"] = "%1 h ago",
    ["há %1 d"] = "%1 d ago",
    ["%1/%2/%3"] = "%2/%1/%3",
    ["%1/%2/%3 %4"] = "%2/%1/%3 %4",

    -- generic
    ["%1, de %2"] = "%1, by %2",
    ["%1 · em %2"] = "%1 · in %2",
    ["Carregando…"] = "Loading…",
    ["Falha: %1"] = "Failed: %1",
    ["Falha ao buscar dados: %1"] = "Failed to fetch data: %1",
    ["Cancelar"] = "Cancel",
    ["Enviar"] = "Send",
    ["Salvar"] = "Save",
    ["Criar"] = "Create",
    ["Voltar"] = "Back",
    ["Apagar"] = "Delete",
    ["Apagando…"] = "Deleting…",
    ["Atualizar"] = "Refresh",
    ["Buscar"] = "Search",
    ["Nenhum resultado."] = "No results.",

    -- highlight dialog
    ["Publicar no Inkwell"] = "Post to Inkwell",
    ["Usar como bio no Inkwell"] = "Use as Inkwell bio",

    -- feed and posts
    ["Comentários (%1)"] = "Comments (%1)",
    ["Comentários"] = "Comments",
    ["Nenhum post ainda."] = "No posts yet.",
    ["Seguindo ✓"] = "Following ✓",
    ["Seguir"] = "Follow",
    ["Seguindo"] = "Following",
    ["Seguidores"] = "Followers",
    ["Curtindo…"] = "Liking…",
    ["Removendo curtida…"] = "Removing like…",
    ["Seguindo…"] = "Following…",
    ["Deixando de seguir…"] = "Unfollowing…",
    ["Fechar emojis"] = "Close emojis",
    ["Novo post"] = "New post",
    ["Citar post"] = "Quote post",
    ["Novo post em %1"] = "New post in %1",
    ["Livro: %1"] = "Book: %1",
    ["O que você quer compartilhar?"] = "What do you want to share?",
    ["Título (opcional)"] = "Title (optional)",
    ["Hashtags (ex: kindle, leitura)"] = "Hashtags (e.g. kindle, reading)",
    ["Publicar"] = "Post",
    ["Escreva algo para publicar."] = "Write something to post.",
    ["Publicando…"] = "Posting…",
    ["Falha ao publicar: %1"] = "Failed to post: %1",
    ["Publicado no Inkwell!"] = "Posted to Inkwell!",
    ["Novo post…"] = "New post…",
    ["Atividade"] = "Activity",
    ["‹ anterior"] = "‹ previous",
    ["próxima ›"] = "next ›",
    ["pág. %1 de %2"] = "page %1 of %2",
    ["Descobrir"] = "Discover",
    ["Nada por aqui ainda. Siga leitores para ver os posts deles, ou veja a aba Descobrir."] =
        "Nothing here yet. Follow readers to see their posts, or check the Discover tab.",

    -- reviews
    ["Resenhas"] = "Reviews",
    ["Nenhuma resenha ainda."] = "No reviews yet.",
    ["Nova resenha…"] = "New review…",
    ["Nova resenha"] = "New review",
    ["Título da resenha"] = "Review title",
    ["Sua resenha"] = "Your review",
    ["Livro"] = "Book",
    ["Autor (opcional)"] = "Author (optional)",
    ["Escolha uma nota de 0 a 5."] = "Pick a rating from 0 to 5.",
    ["Informe o livro."] = "Enter the book.",
    ["Resenha precisa de título e texto."] = "A review needs a title and text.",

    -- comments
    ["Responder a @%1"] = "Reply to @%1",
    ["Comentar"] = "Comment",
    ["Escreva seu comentário…"] = "Write your comment…",
    ["Escreva um comentário."] = "Write a comment.",
    ["Enviando comentário…"] = "Sending comment…",

    -- search
    ["Busque por texto ou livro, #hashtag, ou @usuário para ver os posts de alguém."] =
        "Search by text or book, #hashtag, or @user to see someone's posts.",
    ["kindle, #resenha ou @alice"] = "kindle, #review or @alice",
    ["Digite algo para buscar."] = "Type something to search.",
    ["Busca: %1"] = "Search: %1",
    ["Meus posts"] = "My posts",

    -- post screen
    ["Carregando post…"] = "Loading post…",
    ["‹ anteriores"] = "‹ previous",
    ["comentários %1/%2"] = "comments %1/%2",
    ["próximos ›"] = "next ›",
    ["Apagar post"] = "Delete post",
    ["Apagar este post e todos os seus comentários?"] = "Delete this post and all its comments?",
    ["Citar"] = "Quote",
    ["↪ citado"] = "↪ quoted",
    ["Ninguém comentou ainda. Seja o primeiro!"] = "No comments yet. Be the first!",
    ["Responder"] = "Reply",
    ["Apagar este comentário? As respostas a ele também serão apagadas."] =
        "Delete this comment? Its replies will be deleted too.",
    ["Post apagado."] = "Post deleted.",
    ["Apagando comentário…"] = "Deleting comment…",

    -- profiles, people, shelf, books
    ["Carregando perfil…"] = "Loading profile…",
    ["moderador"] = "moderator",
    ["%1 · segue você"] = "%1 · follows you",
    ["Masculino"] = "Male",
    ["Feminino"] = "Female",
    ["Outro"] = "Other",
    ["%1 anos"] = "%1 years old",
    ["Perfil público"] = "Public profile",
    ["Perfil privado"] = "Private profile",
    ["Editar perfil…"] = "Edit profile…",
    ["%1 seguidores"] = "%1 followers",
    ["%1 seguindo"] = "%1 following",
    ["Seguindo ✓ (toque para deixar de seguir)"] = "Following ✓ (tap to unfollow)",
    ["Lendo agora: %1 (%2%)"] = "Reading now: %1 (%2%)",
    ["Estante (%1 livros)"] = "Shelf (%1 books)",
    ["Seguidores de @%1"] = "@%1's followers",
    ["@%1 segue"] = "@%1 follows",
    ["Ninguém por aqui ainda."] = "Nobody here yet.",
    ["Quero ler"] = "Want to read",
    ["quer ler"] = "wants to read",
    ["Tirar da estante"] = "Remove from shelf",
    ["Marcar como lido"] = "Mark as read",
    ["Ler de novo"] = "Read again",
    ["Postar que você começou a ler “%1”?"] = "Post that you started reading “%1”?",
    ["Postar que você terminou “%1”?"] = "Post that you finished “%1”?",
    ["Agora não"] = "Not now",
    ["Postar…"] = "Post…",
    ["Resenhar…"] = "Review…",
    ["Leitores (%1)"] = "Readers (%1)",
    ["leu"] = "read",
    ["lendo · %1%"] = "reading · %1%",

    -- activity
    ["%1 curtiu seu post"] = "%1 liked your post",
    ["%1 comentou no seu post"] = "%1 commented on your post",
    ["%1 respondeu seu comentário"] = "%1 replied to your comment",
    ["%1 mencionou você"] = "%1 mentioned you",
    ["%1 começou a seguir você"] = "%1 started following you",
    ["%1 curtiu seu comentário"] = "%1 liked your comment",
    ["%1 citou seu post"] = "%1 quoted your post",
    ["%1 pediu para entrar em %2"] = "%1 asked to join %2",
    ["%1 aprovou sua entrada em %2"] = "%1 approved you in %2",
    ["Nada de novo por aqui. Curtidas, comentários e novos seguidores aparecem nesta tela."] =
        "Nothing new here. Likes, comments and new followers show up on this screen.",

    -- nav menu
    ["Início"] = "Home",
    ["Meu perfil"] = "My profile",
    ["Comunidades"] = "Communities",
    ["Criar moderador…"] = "Create moderator…",
    ["Sair (@%1)"] = "Log out (@%1)",
    ["Com o compartilhamento de leituras ligado, o Inkwell pergunta se você quer postar quando começa ou termina um livro."] =
        "With reading sharing on, Inkwell asks whether you want to post when you start or finish a book.",
    ["Compartilhar leituras: ligado ✓"] = "Share reading: on ✓",
    ["Compartilhar leituras: desligado"] = "Share reading: off",
    ["Idioma: Português (Brasil)"] = "Language: English",

    -- profile editing
    ["Editar perfil"] = "Edit profile",
    ["Nome de exibição"] = "Display name",
    ["Idade"] = "Age",
    ["Escolher foto de perfil…"] = "Choose profile photo…",
    ["Gênero"] = "Gender",
    ["Visibilidade"] = "Visibility",
    ["Não foi possível abrir a imagem"] = "Couldn't open the image",
    ["Não foi possível converter a imagem"] = "Couldn't convert the image",
    ["Capa da comunidade atualizada!"] = "Community cover updated!",
    ["Enviando capa…"] = "Uploading cover…",
    ["Enviando foto…"] = "Uploading photo…",
    ["Falha ao enviar foto: %1"] = "Failed to upload photo: %1",
    ["Foto de perfil atualizada!"] = "Profile photo updated!",
    ["Salvando perfil…"] = "Saving profile…",
    ["Falha ao salvar perfil: %1"] = "Failed to save profile: %1",
    ["Perfil atualizado!"] = "Profile updated!",
    ["Criar moderador"] = "Create moderator",
    ["Servidor (ex.: https://api.exemplo.com)"] = "Server (e.g. https://api.example.com)",
    ["Informe email e senha."] = "Enter email and password.",
    ["Moderador @%1 criado!"] = "Moderator @%1 created!",
    ["Criando moderador…"] = "Creating moderator…",

    -- communities
    ["%1 posts · @%2"] = "%1 posts · @%2",
    ["Aguardando aprovação"] = "Awaiting approval",
    ["Minhas comunidades"] = "My communities",
    ["Você ainda não faz parte de nenhuma comunidade. Crie uma do zero ou participe de uma abaixo."] =
        "You're not in any community yet. Create one from scratch or join one below.",
    ["Criar comunidade do zero"] = "Create a community from scratch",
    ["Criar comunidade…"] = "Create community…",
    ["Criar comunidade"] = "Create community",
    ["Título"] = "Title",
    ["Descrição (opcional)"] = "Description (optional)",
    ["Informe o título da comunidade."] = "Enter the community title.",
    ["Comunidade \"%1\" criada!"] = "Community \"%1\" created!",
    ["Criando comunidade…"] = "Creating community…",
    ["Carregando comunidade…"] = "Loading community…",
    ["criada por @%1 · %2 membros · %3 posts"] = "created by @%1 · %2 members · %3 posts",
    ["Trocar capa…"] = "Change cover…",
    ["Escolher capa…"] = "Choose cover…",
    ["Sair da comunidade"] = "Leave community",
    ["Participar"] = "Join",
    ["Pedir para participar"] = "Ask to join",
    ["Cancelar pedido"] = "Cancel request",
    ["Pedido enviado. @%1 precisa aprovar."] = "Request sent. @%1 needs to approve it.",
    ["Pedido cancelado."] = "Request cancelled.",
    ["Tornar pública"] = "Make public",
    ["Tornar privada"] = "Make private",
    ["Tornar a comunidade pública? Todos passam a ver os posts, e os pedidos pendentes são aprovados."] =
        "Make the community public? Everyone will see its posts, and pending requests are approved.",
    ["Pedidos para entrar (%1)"] = "Join requests (%1)",
    ["Aprovar"] = "Approve",
    ["Recusar"] = "Refuse",
    ["Seu pedido foi enviado. Os posts aparecem aqui quando @%1 aprovar."] =
        "Your request was sent. Posts show up here once @%1 approves it.",
    ["Comunidade privada: só membros veem os posts. Peça para participar e aguarde a aprovação de @%1."] =
        "Private community: only members see its posts. Ask to join and wait for @%1 to approve.",
    ["Entrando na comunidade…"] = "Joining community…",
    ["Saindo da comunidade…"] = "Leaving community…",
    ["Agora você faz parte de %1."] = "You're now a member of %1.",
    ["Você saiu de %1."] = "You left %1.",

    -- login / register
    ["Moderador"] = "Moderator",
    ["Usuário"] = "User",
    ["Entrando…"] = "Logging in…",
    ["Entrar no Inkwell"] = "Log in to Inkwell",
    ["Senha"] = "Password",
    ["Criar conta"] = "Sign up",
    ["Entrar"] = "Log in",
    ["Login rápido (contas de teste)"] = "Quick login (test accounts)",
    ["Criando conta…"] = "Creating account…",
    ["Conta criada! Bem-vindo(a), @%1."] = "Account created! Welcome, @%1.",
    ["Criar conta no Inkwell"] = "Sign up for Inkwell",
    ["Você saiu do Inkwell."] = "You logged out of Inkwell.",

    -- client.lua errors
    ["Você precisa fazer login primeiro"] = "You need to log in first",
    ["Sessão expirada, faça login novamente"] = "Session expired, please log in again",
    ["Você não tem permissão para isso"] = "You don't have permission to do that",
    ["Não foi possível abrir o arquivo de imagem"] = "Couldn't open the image file",
    ["Arquivo de imagem vazio"] = "Empty image file",
    ["Avatar vazio"] = "Empty avatar",
    ["Não foi possível salvar o avatar localmente"] = "Couldn't save the avatar locally",

}

local I18n = {}

-- "en" (default) or "pt_BR".
function I18n.lang()
    return G_reader_settings:readSetting(SETTING) or "en"
end

function I18n.toggle()
    G_reader_settings:saveSetting(SETTING, I18n.lang() == "en" and "pt_BR" or "en")
end

-- Callable module: _(msgid).
return setmetatable(I18n, {
    __call = function(_self, msgid)
        if I18n.lang() == "pt_BR" then
            return msgid
        end
        return EN[msgid] or msgid
    end,
})
