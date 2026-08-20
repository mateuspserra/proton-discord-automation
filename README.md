# Automação Proton VPN + Discord

Automação para Windows criada para auxiliar no uso do recurso de transmissão do Discord.

O script conecta temporariamente ao Proton VPN, reinicia o Discord e, depois, desconecta a VPN e confirma o retorno da conexão normal.

> A automação prepara o Discord, mas não inicia a transmissão automaticamente.

## Como funciona

1. Abre e conecta o Proton VPN.
2. Aguarda a conexão da VPN.
3. Reinicia o Discord.
4. Desconecta o Proton VPN.
5. Confirma o retorno da internet.
6. Fecha a interface do Proton.

## Primeiro uso

Antes da primeira execução:

1. Ative a conexão automática no Proton VPN.
2. Configure o Kill Switch como `Standard` ou `Off`.
3. Não utilize o modo `Advanced`.

Essa configuração precisa ser realizada somente uma vez.

## Uso normal

Nas próximas utilizações:

1. Abra o Discord.
2. Execute `executar.bat`.
3. Confirme a permissão de administrador.
4. Aguarde a conclusão.
5. Volte ao Discord e inicie sua transmissão.

## Download

[Baixar a versão mais recente](https://github.com/mateuspserra/proton-discord-automation/releases/latest)

Arquivo disponível:

```text
automacao-proton-discord-v1.0.0.zip
```

## Observações

- Não execute o BAT diretamente de dentro do ZIP.
- Não feche o Proton ou o Discord durante a automação.
- `ProtonVPNService` pode continuar no Gerenciador de Tarefas.
- Atualizações do Discord ou Proton podem exigir ajustes.

## Suporte

Encontrou algum problema?

[Abra uma issue](https://github.com/mateuspserra/proton-discord-automation/issues)

## Licença

Distribuído sob a [Licença MIT](LICENSE.txt).

## Autor

Desenvolvido por [@mateuspserra](https://github.com/mateuspserra).
